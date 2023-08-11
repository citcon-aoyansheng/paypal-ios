import Foundation
import AuthenticationServices
#if canImport(CorePayments)
import CorePayments
#endif

public class CardClient: NSObject {

    public weak var delegate: CardDelegate?
    public weak var vaultDelegate: CardVaultDelegate?
    
    private let apiClient: APIClient
    private let config: CoreConfig
    private let webAuthenticationSession: WebAuthenticationSession
    private var analyticsService: AnalyticsService?
    private var graphQLClient: GraphQLClient?

    /// Initialize a CardClient to process card payment
    /// - Parameter config: The CoreConfig object
    public init(config: CoreConfig) {
        self.config = config
        self.apiClient = APIClient(coreConfig: config)
        self.webAuthenticationSession = WebAuthenticationSession()
        self.graphQLClient = GraphQLClient(environment: config.environment)
    }

    /// For internal use for testing/mocking purpose
    init(
        config: CoreConfig,
        apiClient: APIClient,
        webAuthenticationSession: WebAuthenticationSession,
        graphQLClient: GraphQLClient? = nil
    ) {
        self.config = config
        self.apiClient = apiClient
        self.webAuthenticationSession = webAuthenticationSession
        self.graphQLClient = graphQLClient
    }
    
    public func vault(vaultRequest: CardVaultRequest) {
        Task {
            guard graphQLClient != nil else {
                // TODO: this will be APIClient after networking layer refactor
                throw CardClientError.unknownError
            }
            do {
                let card = vaultRequest.card
                let setupTokenID = vaultRequest.setupTokenID
                let (updateResult) = try await updateSetupToken(
                    vaultSetupTokenID: setupTokenID,
                    card: card)
                if let result = updateResult {
                    // can it be not approved and end up here?
                    // TODO: handle 3DS contingency with helios link
                    if let link = result.links.first(where: { $0.rel == "approve" && $0.href.contains("helios") }) {
                        let url = link.href
                        print("3DS url \(url)")
                    } else {
                        let vaultResult = CardVaultResult(setupTokenID: result.id, status: result.status)
                        notifyVaultSuccess(for: vaultResult)
                    }
                } else {
                    notifyFailure(with: CardClientError.noVaultTokenDataError)
                }
            } catch  let error as CoreSDKError {
                // TODO: right now, GraphQLError is thrown, but will need to add new
                // errors after refactor
                notifyFailure(with: error)
            } catch {
                notifyFailure(with: CardClientError.vaultTokenError)
            }
        }
    }
    
    func updateSetupToken(
        vaultSetupTokenID: String,
        card: Card
    ) async throws -> TokenDetails? {
        guard let graphQLClient else {
            throw CardClientError.unknownError
        }
        let clientID = config.clientID
        let query = UpdateSetupTokenQuery(clientID: clientID, vaultSetupToken: vaultSetupTokenID, card: card)
        let response: GraphQLQueryResponse<UpdateSetupTokenResponse> = try await graphQLClient.callGraphQL(
            name: "UpdateVaultSetupToken", query: query
        )
        guard let data = response.data
        else {
            return nil
        }
        return data.updateVaultSetupToken
    }
           
    /// Approve an order with a card, which validates buyer's card, and if valid, attaches the card as the payment source to the order.
    /// After the order has been successfully approved, you will need to handle capturing/authorizing the order in your server.
    /// - Parameters:
    ///   - orderId: Order id for approval
    ///   - request: The request containing the card
    /// - Returns: Card result
    /// - Throws: PayPalSDK error if approve order could not complete successfully
    public func approveOrder(request: CardRequest) {
        analyticsService = AnalyticsService(coreConfig: config, orderID: request.orderID)
        analyticsService?.sendEvent("card-payments:3ds:started")
        Task {
            do {
                let confirmPaymentRequest = try ConfirmPaymentSourceRequest(clientID: config.clientID, cardRequest: request)
                let (result) = try await apiClient.fetch(request: confirmPaymentRequest)
                
                if let url: String = result.links?.first(where: { $0.rel == "payer-action" })?.href {
                    analyticsService?.sendEvent("card-payments:3ds:confirm-payment-source:challenge-required")
                    startThreeDSecureChallenge(url: url, orderId: result.id)
                } else {
                    analyticsService?.sendEvent("card-payments:3ds:confirm-payment-source:succeeded")
                    
                    let cardResult = CardResult(orderID: result.id, deepLinkURL: nil)
                    notifySuccess(for: cardResult)
                }
            } catch let error as CoreSDKError {
                analyticsService?.sendEvent("card-payments:3ds:confirm-payment-source:failed")
                notifyFailure(with: error)
            } catch {
                analyticsService?.sendEvent("card-payments:3ds:confirm-payment-source:failed")
                notifyFailure(with: CardClientError.unknownError)
            }
        }
    }

    private func startThreeDSecureChallenge(
        url: String,
        orderId: String
    ) {
        guard let threeDSURL = URL(string: url) else {
            self.notifyFailure(with: CardClientError.threeDSecureURLError)
            return
        }
        
        delegate?.cardThreeDSecureWillLaunch(self)
        
        webAuthenticationSession.start(
            url: threeDSURL,
            context: self,
            sessionDidDisplay: { [weak self] didDisplay in
                if didDisplay {
                    self?.analyticsService?.sendEvent("card-payments:3ds:challenge-presentation:succeeded")
                } else {
                    self?.analyticsService?.sendEvent("card-payments:3ds:challenge-presentation:failed")
                }
            },
            sessionDidComplete: { url, error in
                self.delegate?.cardThreeDSecureDidFinish(self)
                if let error = error {
                    switch error {
                    case ASWebAuthenticationSessionError.canceledLogin:
                        self.notifyCancellation()
                        return
                    default:
                        self.notifyFailure(with: CardClientError.threeDSecureError(error))
                        return
                    }
                }
                
                let cardResult = CardResult(orderID: orderId, deepLinkURL: url)
                self.notifySuccess(for: cardResult)
            }
        )
    }

    private func notifySuccess(for result: CardResult) {
        analyticsService?.sendEvent("card-payments:3ds:succeeded")
        delegate?.card(self, didFinishWithResult: result)
    }

    private func notifyFailure(with error: CoreSDKError) {
        analyticsService?.sendEvent("card-payments:3ds:failed")
        delegate?.card(self, didFinishWithError: error)
    }
    
    private func notifyVaultSuccess(for vaultResult: CardVaultResult) {
        vaultDelegate?.card(self, didFinishWithVaultResult: vaultResult)
    }

    private func notifyVaultFailure(with vaultError: CoreSDKError) {
        vaultDelegate?.card(self, didFinishWithVaultError: vaultError)
    }

    private func notifyCancellation() {
        analyticsService?.sendEvent("card-payments:3ds:challenge:user-canceled")
        delegate?.cardDidCancel(self)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding conformance

extension CardClient: ASWebAuthenticationPresentationContextProviding {

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if #available(iOS 15, *) {
            let firstScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = firstScene?.windows.first { $0.isKeyWindow }
            return window ?? ASPresentationAnchor()
        } else {
            let window = UIApplication.shared.windows.first { $0.isKeyWindow }
            return window ?? ASPresentationAnchor()
        }
    }
}

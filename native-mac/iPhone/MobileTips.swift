import CryptoKit
import Observation
import StoreKit
import SwiftUI

/// Optional consumable tips never unlock or restrict app features.
@MainActor @Observable
final class MobileTipStore {
    static let productIDs = ["small", "medium", "large"].map { "com.protomota.inkspring.tip." + $0 }
    private(set) var products: [Product] = []
    private(set) var loading = false
    private(set) var purchasingID: String?
    private(set) var message: String?
    private(set) var completed = false
    private(set) var pendingIDs: Set<String> = []
    private(set) var hasSupported: Bool
    struct Celebration: Identifiable {
        let id = UUID()
        let startedAt = Date()
    }
    private(set) var celebration: Celebration?
    private var recognized: Set<String>
    private let recognizedKey = "inkspring.tips.recognizedPurchases.v1"
    private let defaults: UserDefaults
    private let supportKey = "inkspring.tips.hasSupported.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasSupported = defaults.bool(forKey: supportKey)
        recognized = Set(defaults.stringArray(forKey: recognizedKey) ?? [])
    }

    /// Owned by the app root, so approvals still complete after the sheet closes.
    func observeTransactions() async {
        for await result in StoreKit.Transaction.updates {
            guard !Task.isCancelled else { return }
            await accept(result)
        }
    }

    func recoverPurchases() async {
        for await result in StoreKit.Transaction.unfinished { await accept(result) }
    }

    func load() async {
        guard !loading, purchasingID == nil else { return }
        loading = true
        defer { loading = false }
        message = nil
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            guard !Task.isCancelled else { return }
            products = Self.productIDs.compactMap { id in
                fetched.first { $0.id == id && $0.type == .consumable }
            }
            if products.isEmpty { message = "Tips aren’t available right now. Please try again later." }
        } catch {
            message = "Couldn’t load tips from the App Store. Check your connection and try again."
        }
    }

    func purchase(_ product: Product) async {
        guard purchasingID == nil, !pendingIDs.contains(product.id),
              products.contains(where: { $0.id == product.id }), AppStore.canMakePayments else {
            message = "Purchases aren’t available right now. Check your device’s purchase restrictions."
            return
        }
        purchasingID = product.id
        completed = false
        message = nil
        defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let result): await accept(result)
            case .pending:
                pendingIDs.insert(product.id)
                message = "Your tip is waiting for App Store approval. You can keep using Inkspring."
            case .userCancelled: break
            @unknown default: message = "Apple couldn’t confirm this tip. Check the App Store before trying again."
            }
        } catch {
            message = "Your tip couldn’t be confirmed. Check the App Store result before trying again."
        }
    }

    func endCelebration(_ id: UUID) {
        if celebration?.id == id { celebration = nil }
    }

    /// Only called with a paid, owned Inkspring support credit returned by the server.
    func recordVerifiedSupport(_ purchaseID: String) {
        let key = SHA256.hash(data: Data(("support:" + purchaseID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        defaults.set(true, forKey: supportKey)
        hasSupported = true
        recognized.formUnion(defaults.stringArray(forKey: recognizedKey) ?? [])
        if recognized.insert(key).inserted {
            defaults.set(recognized.sorted(), forKey: recognizedKey)
            celebration = Celebration()
        }
    }

    private func accept(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else {
            message = "Apple couldn’t verify this purchase. No tip has been recorded in Inkspring."
            return
        }
        guard Self.productIDs.contains(transaction.productID), transaction.productType == .consumable else { return }
        pendingIDs.remove(transaction.productID)
        if transaction.revocationDate == nil {
            // Record before finishing, so an interruption can safely recover this purchase.
            defaults.set(true, forKey: supportKey)
            hasSupported = true
            completed = true
            message = nil
            let key = SHA256.hash(data: Data(("tip:" + String(transaction.id)).utf8))
                .map { String(format: "%02x", $0) }.joined()
            recognized.formUnion(defaults.stringArray(forKey: recognizedKey) ?? [])
            if recognized.insert(key).inserted {
                defaults.set(recognized.sorted(), forKey: recognizedKey)
                celebration = Celebration()
            }
        }
        await transaction.finish()
    }
}

struct MobileTipSheet: View {
    @Environment(MobileTipStore.self) private var store
    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Support Inkspring").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).modifier(MobileTipGlass())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .disabled(store.purchasingID != nil)
                    .accessibilityIdentifier("tips.close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.hasSupported {
                        successConfirmation
                        Text("Leave another tip (optional)").font(.headline)
                    } else {
                        HStack(spacing: 16) {
                            Image("InkspringBrand")
                                .resizable().scaledToFit().frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 15))
                                .shadow(color: palette.colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.16), radius: 8, y: 3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Free software.\nSupported by people.").font(.headline)
                                Text("Every feature stays free.").font(.subheadline).foregroundStyle(palette.muted)
                            }
                        }
                        Text("Leave an optional, one-time tip to support continued development. All writing features are free.")
                            .foregroundStyle(palette.muted)
                    }
                    VStack(spacing: 12) {
                        if store.loading { ProgressView("Loading tips…").frame(maxWidth: .infinity) }
                        ForEach(store.products) { product in
                            Button { Task { await store.purchase(product) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cup.and.saucer").foregroundStyle(palette.iconAccent)
                                    Text(product.displayName).fontWeight(.medium)
                                    Spacer()
                                    if store.purchasingID == product.id { ProgressView() }
                                    else if store.pendingIDs.contains(product.id) { Text("Pending").font(.caption) }
                                    else { Text(product.displayPrice).fontWeight(.semibold).monospacedDigit() }
                                }
                                .foregroundStyle(palette.text)
                                .padding(.horizontal, 18).frame(minHeight: 56)
                                .modifier(MobileTipGlass())
                            }
                            .buttonStyle(.plain)
                            .disabled(store.purchasingID != nil || store.pendingIDs.contains(product.id))
                            .accessibilityIdentifier("tips." + product.id)
                        }
                    }
                    if let message = store.message {
                        Text(message).font(.callout).accessibilityIdentifier("tips.status")
                        if store.products.isEmpty && !store.loading {
                            Button("Try again") { Task { await store.load() } }.buttonStyle(.bordered)
                        }
                    }
                    Text("Each tip is a separate App Store purchase. No subscription and no paid upgrade.")
                        .font(.footnote).foregroundStyle(palette.muted)
                    StudioExternalLink("Privacy policy", destination: URL(string: "https://inkspring.ai/privacy/")!).font(.footnote)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .foregroundStyle(palette.text)
        .background(palette.canvas)
        .tint(palette.accent)
        .modifier(InkspringSupporterCelebration())
        .interactiveDismissDisabled(store.purchasingID != nil)
        .task { await store.load() }
    }

    private var successConfirmation: some View {
        let showsCurrentSuccess = store.completed && store.purchasingID == nil && store.message == nil
        return VStack(spacing: 10) {
            InkspringSupporterEmblem(animationID: store.celebration?.id)
            Text("Inkspring Supporter")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("inkspringSupporterBadge")
            VStack(spacing: 5) {
                Text(showsCurrentSuccess ? "Tip completed" : "Thank you for your support")
                    .font(.title3.bold())
                    .accessibilityIdentifier("tips.success")
                Text(showsCurrentSuccess
                     ? "Thank you for supporting development. You’re all set—no further action is needed."
                     : "Your previous tip was received. You can leave another tip whenever you’d like.")
                    .font(.callout)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tipJarSuccess")
    }
}

private struct MobileTipGlass: ViewModifier {
    @Environment(\.studioPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if palette.theme == .paper {
            content.studioPaperControl(in: Capsule(), fill: palette.control)
        } else if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(palette.control, in: Capsule())
                .overlay { Capsule().strokeBorder(palette.accent.opacity(0.4)) }
        }
    }
}

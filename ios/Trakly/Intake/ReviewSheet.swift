import SwiftUI
import TraklyCore

/// The state of S6 (docs/specs/phase10-apps-and-stores.md §B6): the product as product-link answered it, the chosen
/// options (a one-value option preselected), «شرح کالا», the brand switch, the quantity (composer only) and the photo.
@MainActor
final class ReviewState: ObservableObject {
    let product: JSONObject
    let line: Bool
    let options: [VariantMatcher.Option]
    @Published var chosen: [String: String]
    @Published var title: String
    @Published var withBrand = true
    @Published var quantity = 1
    @Published var selectedImage: String?
    @Published var saving = false

    init(product: JSONObject, line: Bool) {
        self.product = product
        self.line = line
        options = VariantMatcher.options(product)
        let preselected = VariantMatcher.preselected(product)
        chosen = preselected
        title = (product.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        selectedImage = VariantMatcher.images(product, preselected).first
    }

    var images: [String] { VariantMatcher.images(product, chosen) }
    var brand: String? { product.string("brand").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
    var host: String { Policy.hostOf(product.string("url")) ?? product.string("site") ?? "" }
    var price: String? { VariantMatcher.price(product, chosen) }
    var comboUnavailable: Bool { VariantMatcher.comboUnavailable(product, chosen) }
    var missing: [String] { VariantMatcher.missingLabels(product, chosen) }

    func choose(_ name: String, _ value: String) {
        if chosen[name] == value {
            chosen.removeValue(forKey: name)
        } else {
            chosen[name] = value
        }
        selectedImage = VariantMatcher.imageAfterChoice(product, chosen, current: selectedImage)
        Haptics.play("selection")
    }
}

@MainActor
struct ReviewActions {
    let add: (ReviewState, Bool) -> Void
    let cancel: () -> Void
    let thumbnail: (String) async -> UIImage?
}

/// S6 «انتخاب مشخصات» (§B6, §E6): exactly the fields and the copy of the web import dialog: the host and brand chips,
/// «عکس قلم», «شرح کالا» (its direction from its content), each option's chips (struck through and «در سایت ناموجود» when
/// unavailable; the chip area capped at 176 pt), the brand switch, «قیمت در سایت:» as a LTR run, the unavailable
/// combination, «تعداد» (composer only), and the buttons pinned in a footer outside the scroll area.
struct ReviewSheet: View {
    @ObservedObject var state: ReviewState
    let actions: ReviewActions

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    chips
                    photos
                    titleField
                    ForEach(state.options, id: \.name) { option in
                        optionView(option)
                    }
                    if let brand = state.brand {
                        Toggle(isOn: $state.withBrand) {
                            Text(L.f("review_brand", FaText.ltr(brand)))
                                .font(Theme.swiftUIFont(15))
                                .foregroundStyle(Color(Theme.ink))
                        }
                        .tint(Color(Theme.brand))
                        .accessibilityIdentifier("review.brand")
                    }
                    if let price = state.price {
                        HStack(spacing: 6) {
                            Text(L.s("review_price"))
                                .font(Theme.swiftUIFont(14))
                                .foregroundStyle(Color(Theme.ink2))
                            Text(price)
                                .font(Theme.swiftUIFont(14, bold: true))
                                .foregroundStyle(Color(Theme.ink))
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if state.comboUnavailable {
                        Label(L.s("review_combo_unavailable"), systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.swiftUIFont(14, bold: true))
                            .foregroundStyle(Color(Theme.warningInk))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(Theme.warningSoft), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    }
                    if !state.line {
                        quantity
                    }
                }
                .padding(16)
            }
            .background(Color(Theme.surface))
            .navigationTitle(L.s("review_title"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                footer
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .tint(Color(Theme.brand))
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip(state.host, soft: true)
            if let brand = state.brand {
                chip(brand, soft: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, soft: Bool) -> some View {
        Text(text)
            .font(Theme.swiftUIFont(12, bold: true, relativeTo: .caption))
            .foregroundStyle(Color(soft ? Theme.brandInk : Theme.ink2))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(soft ? Theme.brandSoft : Theme.surface3), in: Capsule())
            .environment(\.layoutDirection, .leftToRight)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.swiftUIFont(14, bold: true, relativeTo: .subheadline))
            .foregroundStyle(Color(Theme.ink2))
    }

    private var photos: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(L.s("review_photo"))
            let images = state.images
            if images.isEmpty {
                Text(L.s("review_no_photo"))
                    .font(Theme.swiftUIFont(13))
                    .foregroundStyle(Color(Theme.ink3))
                    .accessibilityIdentifier("review.nophoto")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images, id: \.self) { url in
                            Button {
                                state.selectedImage = url
                                Haptics.play("selection")
                            } label: {
                                Thumbnail(url: url, load: actions.thumbnail)
                                    .frame(width: 92, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                            .stroke(state.selectedImage == url ? Color(Theme.brand) : Color(Theme.line), lineWidth: state.selectedImage == url ? 3 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(state.selectedImage == url ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(L.s("review_desc"))
            TextField("", text: $state.title)
                .font(Theme.swiftUIFont(16))
                .multilineTextAlignment(FaText.startsRightToLeft(state.title) ? .leading : .trailing)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color(Theme.surface2), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Color(Theme.line), lineWidth: 1))
                .onChange(of: state.title) {
                    if state.title.utf16.count > BridgeMessages.Limit.choiceTitleChars {
                        state.title = String(state.title.prefix(BridgeMessages.Limit.choiceTitleChars))
                    }
                }
                .accessibilityIdentifier("review.title")
        }
    }

    private func optionView(_ option: VariantMatcher.Option) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                label(option.label.isEmpty ? option.name : option.label)
                if !option.label.isEmpty && option.label != option.name {
                    Text(option.name)
                        .font(Theme.swiftUIFont(12))
                        .foregroundStyle(Color(Theme.ink3))
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(option.values, id: \.self) { value in
                        valueChip(option, value)
                    }
                }
            }
            .frame(maxHeight: option.values.count > 12 ? 176 : nil)
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.option")
    }

    private func valueChip(_ option: VariantMatcher.Option, _ value: String) -> some View {
        let selected = state.chosen[option.name] == value
        let available = VariantMatcher.isValueAvailable(state.product, state.chosen, name: option.name, value: value)
        return Button {
            state.choose(option.name, value)
        } label: {
            Text(value)
                .font(Theme.swiftUIFont(14, bold: selected))
                .strikethrough(!available)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color(selected ? Theme.onInk : (available ? Theme.ink : Theme.ink3)))
                .frame(maxWidth: .infinity, minHeight: 40)
                .padding(.horizontal, 8)
                .background(Color(selected ? Theme.ink : Theme.surface2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(selected ? Theme.ink : Theme.line), lineWidth: 1))
                .environment(\.layoutDirection, .leftToRight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(available ? value : value + L.s("list_separator") + L.s("review_unavailable"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var quantity: some View {
        HStack(spacing: 12) {
            label(L.s("review_qty"))
            Spacer(minLength: 0)
            Button {
                state.quantity = max(BridgeMessages.Limit.quantityMin, state.quantity - 1)
                Haptics.play("selection")
            } label: {
                Image(systemName: "minus")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(state.quantity <= BridgeMessages.Limit.quantityMin)
            .accessibilityLabel(L.has("qty_less") ? L.s("qty_less") : "-")
            Text(Fa.number(state.quantity))
                .font(Theme.swiftUIFont(18, bold: true))
                .frame(minWidth: 44)
                .accessibilityIdentifier("review.qty")
            Button {
                state.quantity = min(BridgeMessages.Limit.quantityMax, state.quantity + 1)
                Haptics.play("selection")
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(state.quantity >= BridgeMessages.Limit.quantityMax)
            .accessibilityLabel(L.has("qty_more") ? L.s("qty_more") : "+")
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryTitle: String {
        let missing = state.missing
        if state.line {
            return missing.isEmpty ? L.s("review_import") : L.f("review_import_missing", L.list(missing))
        }
        return missing.isEmpty ? L.s("review_add") : L.f("review_add_missing", L.list(missing))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                actions.add(state, false)
            } label: {
                if state.saving {
                    ProgressView().tint(.white)
                } else {
                    Text(primaryTitle).lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.saving)
            .accessibilityIdentifier("review.add")
            HStack(spacing: 10) {
                if !state.line {
                    Button(L.s("review_add_next")) {
                        actions.add(state, true)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(state.saving)
                    .layoutPriority(2)
                    .accessibilityIdentifier("review.next")
                }
                Button(L.s("review_cancel"), action: actions.cancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(state.saving)
                    .layoutPriority(1)
                    .accessibilityIdentifier("review.cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// A product photo loaded by the native fetcher (no cookies, the address checks of §I3).
struct Thumbnail: View {
    let url: String
    let load: (String) async -> UIImage?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(Theme.surface2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(Color(Theme.ink3))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let loaded = await load(url)
            image = loaded
            failed = loaded == nil
        }
        .accessibilityHidden(true)
    }
}

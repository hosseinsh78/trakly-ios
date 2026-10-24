import SwiftUI
import TraklyCore

/// S4 «سفارش تازه» (docs/specs/phase10-apps-and-stores.md D10, §A2 F1, F3, §D7, §E6): the kept draft row, the link
/// field (left to right) with the icon-only paste control, the clipboard chip, the shared links waiting for «خواندن»,
/// the rows being read, «محصول های این سفارش», «سفارش سریع» and «ثبت سفارش بدون لینک», and the primary «ادامه ثبت سفارش»
/// (merge mode: «افزودن به فرم سفارش باز» with «سفارش تازه») pinned above the keyboard and the home indicator.
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    let actions: ComposerActions
    @FocusState private var linkFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let draftAt = model.draftAt, !model.merge {
                    Section {
                        Button {
                            actions.draft()
                        } label: {
                            Label(L.f("composer_draft", Fa.time(draftAt)), systemImage: "doc.text")
                                .font(Theme.swiftUIFont(15, bold: true))
                                .foregroundStyle(Color(Theme.brandInk))
                        }
                        .accessibilityIdentifier("composer.draft")
                    }
                }

                Section {
                    linkField
                    if let error = model.linkError {
                        Text(error)
                            .font(Theme.swiftUIFont(13))
                            .foregroundStyle(Color(Theme.dangerInk))
                            .accessibilityIdentifier("composer.error")
                    }
                    if model.clipboard {
                        clipboardChip
                    }
                }

                let shared = model.rows.filter { $0.state == .shared }
                if !shared.isEmpty {
                    Section {
                        ForEach(shared) { row in
                            sharedRow(row)
                        }
                    } header: {
                        sectionHeader(L.s("composer_shared"))
                    }
                }

                let working = model.rows.filter { $0.state != .shared }
                if !working.isEmpty {
                    Section {
                        ForEach(working) { row in
                            workingRow(row)
                        }
                    }
                }

                Section {
                    if model.lines.isEmpty {
                        Text(L.s("composer_empty"))
                            .font(Theme.swiftUIFont(14))
                            .foregroundStyle(Color(Theme.ink3))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("composer.empty")
                    } else {
                        ForEach(model.lines, id: \.id) { line in
                            lineRow(line)
                        }
                    }
                } header: {
                    if !model.lines.isEmpty {
                        sectionHeader(L.s("composer_basket"))
                    }
                }

                Section {
                    if model.quick {
                        Button(action: actions.quick) {
                            Label(L.s("composer_quick"), systemImage: "bolt")
                                .font(Theme.swiftUIFont(15))
                                .foregroundStyle(Color(Theme.ink))
                        }
                        .accessibilityIdentifier("composer.quick")
                    }
                    Button(action: actions.blank) {
                        Label(L.s("composer_blank"), systemImage: "square.and.pencil")
                            .font(Theme.swiftUIFont(15))
                            .foregroundStyle(Color(Theme.ink))
                    }
                    .accessibilityIdentifier("composer.blank")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(Theme.canvas))
            .navigationTitle(L.s("composer_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.s("bar_close"), action: actions.close)
                        .font(Theme.swiftUIFont(17))
                        .accessibilityIdentifier("composer.close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .onChange(of: model.focusLink) {
                linkFocused = true
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .tint(Color(Theme.brand))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.swiftUIFont(13, bold: true, relativeTo: .footnote))
            .foregroundStyle(Color(Theme.ink2))
    }

    private var linkField: some View {
        HStack(spacing: 10) {
            TextField("", text: $model.link, prompt: Text(L.s("composer_hint")).font(Theme.swiftUIFont(15)).foregroundColor(Color(Theme.ink3)))
                .font(.system(size: 16, design: .default))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($linkFocused)
                .onSubmit {
                    actions.add(model.link)
                }
                .multilineTextAlignment(model.link.isEmpty ? .trailing : .leading)
                .environment(\.layoutDirection, .leftToRight)
                .frame(minHeight: 44)
                .accessibilityIdentifier("composer.link")
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first ?? ""
                Task { @MainActor in
                    actions.add(text)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
            .accessibilityHint(L.s("composer_paste"))
            .accessibilityIdentifier("composer.paste")
        }
    }

    private var clipboardChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Color(Theme.brandInk))
                .accessibilityHidden(true)
            Text(ClipRule.label(L.s("composer_clip")))
                .font(Theme.swiftUIFont(14, bold: true))
                .foregroundStyle(Color(Theme.ink))
            Spacer(minLength: 8)
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first ?? ""
                Task { @MainActor in
                    actions.add(text)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .accessibilityHint(L.s("composer_clip_add"))
            .accessibilityIdentifier("composer.clip")
        }
        .padding(.vertical, 2)
    }

    private func hostChip(_ host: String) -> some View {
        Text(host)
            .font(Theme.swiftUIFont(12, bold: true, relativeTo: .caption))
            .foregroundStyle(Color(Theme.brandInk))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(Theme.brandSoft), in: Capsule())
            .environment(\.layoutDirection, .leftToRight)
    }

    private func sharedRow(_ row: ComposerRow) -> some View {
        HStack(spacing: 10) {
            hostChip(row.host)
            Spacer(minLength: 8)
            Button(L.s("composer_read")) {
                actions.read(row.id)
            }
            .buttonStyle(.borderedProminent)
            .font(Theme.swiftUIFont(14, bold: true))
            .accessibilityIdentifier("composer.read")
            Button {
                actions.removeRow(row.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(Theme.ink3))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L.s("composer_row_remove"))
        }
    }

    @ViewBuilder
    private func workingRow(_ row: ComposerRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                hostChip(row.host)
                Spacer(minLength: 8)
                switch row.state {
                case .fetching, .reading:
                    ProgressView()
                    Text(L.s(row.state == .reading ? "composer_row_reading" : "composer_row_fetching"))
                        .font(Theme.swiftUIFont(13))
                        .foregroundStyle(Color(Theme.ink2))
                case .failed:
                    Text(L.s("composer_row_failed"))
                        .font(Theme.swiftUIFont(13, bold: true))
                        .foregroundStyle(Color(Theme.dangerInk))
                case .shared:
                    EmptyView()
                }
            }
            if row.state == .failed {
                HStack(spacing: 10) {
                    Button(L.s("composer_row_retry")) {
                        actions.read(row.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("composer.retry")
                    Button(L.s("composer_row_bare")) {
                        actions.bare(row.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("composer.bare")
                    Spacer(minLength: 0)
                    Button {
                        actions.removeRow(row.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Color(Theme.dangerInk))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L.s("composer_row_remove"))
                }
                .font(Theme.swiftUIFont(13, bold: true))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.row")
    }

    private func values(of line: Basket.Line) -> String {
        guard let chosen = line.choice.object("chosen") else { return "" }
        let parts = chosen.compactMap { $0.1.stringValue }
        return L.list(parts)
    }

    private func lineRow(_ line: Basket.Line) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = actions.image(line.thumb) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Color(Theme.ink3))
                }
            }
            .frame(width: 52, height: 52)
            .background(Color(Theme.surface2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.title)
                    .font(Theme.swiftUIFont(15, bold: true))
                    .foregroundStyle(Color(Theme.ink))
                    .lineLimit(2)
                let shown = values(of: line)
                if !shown.isEmpty {
                    Text(shown)
                        .font(Theme.swiftUIFont(13))
                        .foregroundStyle(Color(Theme.ink2))
                        .lineLimit(1)
                }
                Text(L.f("composer_row_qty", Fa.number(line.quantity)))
                    .font(Theme.swiftUIFont(13))
                    .foregroundStyle(Color(Theme.ink3))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                actions.removeLine(line.id)
            } label: {
                Text(L.s("composer_row_remove"))
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                actions.removeLine(line.id)
            } label: {
                Label(L.s("composer_row_remove"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.line")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            let count = Fa.number(model.lines.count)
            Button(L.f(model.merge ? "composer_merge" : "composer_continue", count), action: actions.proceed)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.lines.isEmpty)
                .accessibilityIdentifier("composer.continue")
            if model.merge {
                Button(L.s("composer_new_order"), action: actions.newOrder)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.lines.isEmpty)
                    .accessibilityIdentifier("composer.new")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

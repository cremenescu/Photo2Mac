// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    case hand, crop, rotate, tune, text, arrow, rect, blur, info
    var id: String { rawValue }
    var iconName: String { rawValue }
    var label: String {
        switch self {
        case .hand: return t("Mutare")
        case .crop: return t(t("Decupare"))
        case .rotate: return t(t("Rotire"))
        case .tune: return t("Ajustari")
        case .text: return t("Text")
        case .arrow: return t("Sageata")
        case .rect: return t("Dreptunghi")
        case .blur: return t("Blur")
        case .info: return t("Metadate")
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared
    @State private var tool: EditorTool = .hand
    @State private var zoom: CGFloat = 1.0
    @State private var showInspector: Bool = true
    @State private var forceFitNonce: Int = 0
    @StateObject private var cropEdit = CropEditHolder()

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabBarView()
                Divider()
            }

            HSplitView {
                GeometryReader { proxy in
                    ZStack {
                        Color(NSColor(white: 0.12, alpha: 1.0))
                            .ignoresSafeArea()

                        if let doc = workspace.selected {
                            CanvasContainer(doc: doc,
                                            zoom: $zoom,
                                            initialZoomMode: settings.initialZoomMode,
                                            tool: tool,
                                            viewportSize: proxy.size,
                                            forceFitNonce: forceFitNonce,
                                            alwaysRefitOnResize: settings.alwaysRefitOnResize,
                                            cropEditState: cropEdit.state)
                        } else {
                            EmptyWorkspaceView()
                        }
                    }
                }
                .frame(minWidth: 240, minHeight: 200)
                .layoutPriority(1)

                if showInspector {
                    InspectorView(tool: $tool, cropHolder: cropEdit)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                }
            }
        }
        .onOpenURL { url in
            workspace.open(url: url)
        }
        .onChange(of: tool) { oldTool, newTool in
            // Leaving crop tool without explicit Apply/Cancel = cancel (revert).
            if newTool != .crop, let s = cropEdit.state,
               let doc = workspace.selected {
                doc.stack.crop = s.originalStackCrop
                cropEdit.state = nil
            }
            // Re-fit on crop entry/exit (entering = 90% fit so corner handles
            // are reachable; leaving = back to normal fit).
            if oldTool == .crop || newTool == .crop {
                forceFitNonce &+= 1
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url {
                        DispatchQueue.main.async { workspace.open(url: u) }
                    }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ForEach(EditorTool.allCases) { t in
                    Button {
                        tool = t
                    } label: {
                        IconifyImage(name: t.iconName, size: 18)
                            .foregroundStyle(tool == t ? Color.accentColor : Color.primary)
                    }
                    .help(t.label)
                    .disabled(workspace.selected == nil && t != .hand)
                }

                Divider()

                UndoRedoButtons(doc: workspace.selected)
                EditsListButton(doc: workspace.selected)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    zoom = max(0.05, zoom / 1.25)
                } label: { IconifyImage(name: "zoom-out", size: 16) }
                .help(t("Micsoreaza"))
                .disabled(workspace.selected == nil)

                Text(verbatim: String(format: "%d%%", Int((zoom * 100).rounded())))
                    .frame(minWidth: 56)
                    .lineLimit(1)
                    .fixedSize()
                    .monospacedDigit()
                    .foregroundStyle(workspace.selected == nil ? Color.secondary : Color.primary)

                Button {
                    zoom = min(16, zoom * 1.25)
                } label: { IconifyImage(name: "zoom-in", size: 16) }
                .help(t("Mareste"))
                .disabled(workspace.selected == nil)

                Menu {
                    ForEach(InitialZoom.allCases) { mode in
                        Button {
                            settings.initialZoomMode = mode
                            forceFitNonce &+= 1
                        } label: {
                            if settings.initialZoomMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 15, weight: .regular))
                }
                .help(t("Mod vizualizare"))
                .disabled(workspace.selected == nil)

                Toggle(isOn: $showInspector) {
                    IconifyImage(name: "inspector", size: 16)
                }
                .help(t("Inspector"))
            }
        }
    }
}

/// Observes the OpenImage so re-renders (slider live updates) propagate.
/// WorkspaceView only observes `Workspace`, not the individual document.
/// Toolbar button + popover with the list of currently-applied edits.
/// Disabled when there's nothing to show.
struct EditsListButton: View {
    let doc: OpenImage?

    var body: some View {
        if let doc = doc {
            EditsListButtonActive(doc: doc)
        } else {
            Button {} label: { IconifyImage(name: "edits", size: 18) }
                .help(t("Editari"))
                .disabled(true)
        }
    }
}

private struct EditsListButtonActive: View {
    @ObservedObject var doc: OpenImage
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            IconifyImage(name: "edits", size: 18)
        }
        .help(t("Lista editari aplicate"))
        .disabled(doc.stack.isNeutral)
        .popover(isPresented: $presented, arrowEdge: .top) {
            EditsListView(doc: doc)
                .frame(width: 320)
        }
        // Auto-dismiss when the user opens a menu bar menu or invokes a
        // command that posts the global dismiss-popovers notification (e.g.
        // Save via Cmd+S brings up a modal panel).
        .onReceive(NotificationCenter.default.publisher(
            for: NSMenu.didBeginTrackingNotification)) { _ in
            presented = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .photo2MacDismissPopovers)) { _ in
            presented = false
        }
    }
}

extension Notification.Name {
    static let photo2MacDismissPopovers = Notification.Name("Photo2Mac.dismissPopovers")
}

/// Undo/Redo toolbar buttons that observe the current document's history so
/// they enable/disable reactively as the user makes edits.
struct UndoRedoButtons: View {
    let doc: OpenImage?

    var body: some View {
        if let doc = doc {
            UndoRedoButtonsActive(doc: doc, history: doc.history)
        } else {
            Group {
                Button {} label: { IconifyImage(name: "undo", size: 18) }
                    .help(t("Anuleaza"))
                    .disabled(true)
                Button {} label: { IconifyImage(name: "redo", size: 18) }
                    .help("Refa")
                    .disabled(true)
            }
        }
    }
}

private struct UndoRedoButtonsActive: View {
    @ObservedObject var doc: OpenImage
    @ObservedObject var history: UndoHistory

    var body: some View {
        Button {
            doc.performUndo()
        } label: {
            IconifyImage(name: "undo", size: 18)
        }
        .help(t("Anuleaza ultima actiune (Cmd+Z)"))
        .disabled(!history.canUndo)

        Button {
            doc.performRedo()
        } label: {
            IconifyImage(name: "redo", size: 18)
        }
        .help(t("Refa ultima actiune anulata (Cmd+Shift+Z)"))
        .disabled(!history.canRedo)
    }
}

struct CanvasContainer: View {
    @ObservedObject var doc: OpenImage
    @Binding var zoom: CGFloat
    let initialZoomMode: InitialZoom
    let tool: EditorTool
    let viewportSize: CGSize
    let forceFitNonce: Int
    let alwaysRefitOnResize: Bool
    let cropEditState: CropEditState?

    /// When crop tool is active, show the image with flip/rotate/adjustments
    /// applied but crop temporarily disabled — so the user picks a fresh crop
    /// region on the ALREADY ROTATED / FLIPPED image, not on the raw original.
    /// When Apply commits, the new crop replaces stack.crop and the renderer
    /// re-applies it on top of rotate/flip.
    private var imageToShow: NSImage {
        if let s = cropEditState { return s.preCropImage }
        return doc.displayImage
    }

    var body: some View {
        ImageCanvasView(image: imageToShow,
                        zoom: $zoom,
                        initialZoomMode: initialZoomMode,
                        tool: tool,
                        documentID: doc.id,
                        viewportSize: viewportSize,
                        forceFitNonce: forceFitNonce,
                        alwaysRefitOnResize: alwaysRefitOnResize,
                        cropEditState: cropEditState)
    }
}

struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(workspace.documents) { doc in
                    TabItemView(doc: doc,
                                selected: workspace.selectedID == doc.id)
                        .onTapGesture { workspace.selectedID = doc.id }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct TabItemView: View {
    @EnvironmentObject var workspace: Workspace
    let doc: OpenImage
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(doc.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button {
                workspace.close(doc)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(hovering ? Color.gray.opacity(0.3) : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct EmptyWorkspaceView: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject private var recents = RecentFiles.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left: branding + actions
            VStack(spacing: 14) {
                Image(nsImage: appIcon())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                VStack(spacing: 2) {
                    Text("Photo2Mac")
                        .font(.system(size: 22, weight: .semibold))
                    Text(appVersion())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    actionRow(icon: "folder.fill",
                              title: t(t("Deschide imagine...")),
                              subtitle: t("Selecteaza un fisier de pe disc"),
                              tint: .blue) {
                        workspace.openPanel()
                    }
                }
                .padding(.top, 6)

                Spacer()

                Text(t("Sau trage o imagine oriunde in fereastra"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: 320)
            .padding(28)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Right: recents
            VStack(alignment: .leading, spacing: 0) {
                Text(t("Fisiere recente"))
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                if recents.urls.isEmpty {
                    VStack {
                        Text(t("Niciun fisier recent"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(recents.urls, id: \.self) { url in
                                RecentRow(url: url) {
                                    workspace.open(url: url)
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func actionRow(icon: String, title: String, subtitle: String,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private func appIcon() -> NSImage {
        NSApp.applicationIconImage ?? NSImage()
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}

struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let thumb = makeThumb() {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 42, height: 42)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.gray.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Tiny thumbnail from the file (no full load).
    private func makeThumb() -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 84,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct InspectorView: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var tool: EditorTool
    let cropHolder: CropEditHolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.label)
                .font(.headline)

            Divider()

            Group {
                switch tool {
                case .hand:
                    Text(t("Click-drag pentru a misca imaginea in workspace. Trackpad: scroll pentru pan, pinch pentru zoom."))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .tune:
                    if let doc = workspace.selected {
                        TuneInspector(doc: doc, tool: $tool)
                    } else {
                        Text("Deschide o imagine pentru a ajusta.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .rotate:
                    if let doc = workspace.selected {
                        RotateInspector(doc: doc, tool: $tool)
                    } else {
                        Text("Deschide o imagine pentru rotire.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .crop:
                    if let doc = workspace.selected {
                        CropInspector(doc: doc, holder: cropHolder, tool: $tool)
                    } else {
                        Text("Deschide o imagine pentru decupare.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .info:
                    if let doc = workspace.selected {
                        MetadataInspector(doc: doc)
                    } else {
                        Text("Deschide o imagine pentru a vedea metadatele.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                default:
                    Text("Parametri \(tool.label) — in dezvoltare")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            Spacer()

            if let doc = workspace.selected {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Fisier"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(doc.displayName)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(t("Dimensiune"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("\(Int(doc.originalImage.size.width)) x \(Int(doc.originalImage.size.height)) px")
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MetadataInspector: View {
    @ObservedObject var doc: OpenImage
    @State private var showingRawJSON = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let meta = ImageMetadata.read(from: doc.url) {
                    section(t("Fisier")) {
                        row(t("Nume"), doc.url.lastPathComponent, lineLimit: 2)
                        if let f = meta.formattedFormat { row(t("Format"), f) }
                        if let s = meta.formattedFileSize { row(t("Marime"), s) }
                        if let w = meta.pixelWidth, let h = meta.pixelHeight {
                            row(t("Dimensiune"), "\(w) × \(h) px")
                        }
                        if let cm = meta.colorModel { row(t("Color model"), cm) }
                    }

                    let hasEXIF = meta.cameraMake != nil || meta.cameraModel != nil ||
                                  meta.lens != nil || meta.iso != nil ||
                                  meta.exposureTime != nil || meta.fNumber != nil ||
                                  meta.focalLengthMM != nil || meta.dateTakenISO != nil
                    if hasEXIF {
                        section(t("Captura")) {
                            if let date = meta.dateTakenISO { row(t("Data"), date) }
                            if let m = meta.cameraMake, let mo = meta.cameraModel {
                                row(t("Camera"), "\(m) \(mo)")
                            } else if let m = meta.cameraMake { row(t("Camera"), m) }
                              else if let mo = meta.cameraModel { row(t("Camera"), mo) }
                            if let lens = meta.lens { row(t("Obiectiv"), lens, lineLimit: 2) }
                            if let iso = meta.iso { row(t("ISO"), "\(iso)") }
                            if let s = meta.exposureTime { row(t("Timp expunere"), s) }
                            if let f = meta.fNumber { row(t("Diafragma"), String(format: "f/%.1f", f)) }
                            if let fl = meta.focalLengthMM {
                                row(t("Lungime focala"), String(format: "%.0f mm", fl))
                            }
                        }
                    }

                    section(t("Photo2Mac (XMP)")) {
                        HStack(spacing: 6) {
                            Image(systemName: meta.hasPhoto2MacStack
                                  ? "checkmark.circle.fill"
                                  : "circle.dashed")
                                .foregroundStyle(meta.hasPhoto2MacStack ? Color.green : Color.secondary)
                            Text(meta.hasPhoto2MacStack
                                 ? t("Editari incorporate in fisier")
                                 : t("Fisierul nu contine editari Photo2Mac"))
                                .font(.callout)
                        }
                        if meta.hasPhoto2MacStack {
                            Button {
                                showingRawJSON.toggle()
                            } label: {
                                Text(showingRawJSON ? t("Ascunde JSON") : t("Vezi JSON brut"))
                                    .frame(maxWidth: .infinity)
                            }
                            if showingRawJSON, let json = meta.photo2MacStackJSON {
                                let pretty = prettyPrint(json) ?? json
                                Text(pretty)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(white: 0, opacity: 0.06))
                                    .cornerRadius(4)
                            }
                        }
                    }
                } else {
                    Text(t("Nu am putut citi metadatele fisierului."))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func prettyPrint(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: out, encoding: .utf8)
    }
}

/// Holds the currently-active crop edit state for the workspace.
/// Lives at WorkspaceView scope so tool switches outside crop tool don't drop
/// the state (we just hide the overlay).
final class CropEditHolder: ObservableObject {
    @Published var state: CropEditState?
}

struct AspectPicker: View {
    @ObservedObject var state: CropEditState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Raport"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.aspect },
                set: { state.aspect = $0 }
            )) {
                ForEach(CropAspect.allCases) { a in
                    Text(a.label).tag(a)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

struct CropInspector: View {
    @ObservedObject var doc: OpenImage
    @ObservedObject var holder: CropEditHolder
    @Binding var tool: EditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Trage colturile sau muchiile dreptunghiului. Click in interior pentru a-l muta."))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let state = holder.state {
                AspectPicker(state: state)

                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Dreptunghi (pixeli)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%d, %d  •  %d × %d",
                                Int(state.rect.minX), Int(state.rect.minY),
                                Int(state.rect.width), Int(state.rect.height)))
                        .font(.callout)
                        .monospacedDigit()
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) {
                    cancelCrop()
                }
                Spacer()
                Button(t("Aplica")) {
                    applyCrop()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }

            Button {
                if let s = holder.state {
                    s.aspect = .free
                    s.rect = CGRect(origin: .zero, size: s.imageSize)
                }
            } label: {
                Text(t("Reseteaza"))
                    .frame(maxWidth: .infinity)
            }
            .help(t("Reseteaza dreptunghiul la imaginea intreaga"))
            .padding(.top, 4)
        }
        .onAppear {
            ensureCropState()
        }
    }

    private func ensureCropState() {
        if holder.state == nil {
            // Renders the post-flip/post-rotate/post-adjustments image (with
            // crop disabled) so the user can crop on what they SEE — including
            // any rotation they already applied.
            holder.state = CropEditState(doc: doc)
            doc.stack.crop = nil
        }
    }

    private func applyCrop() {
        guard let s = holder.state else { return }
        // The original-stack snapshot was taken when entering crop mode
        // (ensureCropState already cleared doc.stack.crop). We push that
        // pre-edit snapshot so undo restores the prior crop (or no crop).
        let snapshot = preCropStack(originalCrop: s.originalStackCrop)
        let n = s.normalized
        if abs(n.x) < 0.001 && abs(n.y) < 0.001 &&
            abs(n.width - 1) < 0.001 && abs(n.height - 1) < 0.001 {
            doc.stack.crop = nil
        } else {
            doc.stack.crop = n
        }
        doc.commitSnapshot(snapshot)
        holder.state = nil
        tool = .hand
    }

    private func cancelCrop() {
        // No history push: Cancel reverts the temp edit and leaves stack as
        // it was when the user entered crop mode.
        if let s = holder.state {
            doc.stack.crop = s.originalStackCrop
        }
        holder.state = nil
        tool = .hand
    }

    /// Pre-edit stack = current stack with crop restored to the original value.
    private func preCropStack(originalCrop: CropRect?) -> EditStack {
        var s = doc.stack
        s.crop = originalCrop
        return s
    }
}

struct RotateInspector: View {
    @ObservedObject var doc: OpenImage
    @Binding var tool: EditorTool
    @State private var preToolSnap: EditStack?

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.allowsFloats = true
        f.usesGroupingSeparator = false
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    rotate(by: -90)
                } label: {
                    Label { Text("-90°") } icon: {
                        IconifyImage(name: "rotate-left", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                Button {
                    rotate(by: 90)
                } label: {
                    Label { Text("+90°") } icon: {
                        IconifyImage(name: "rotate-right", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            // Fine rotation: -180 .. +180 in 0.01° steps.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(t("Unghi (°)"))
                        .font(.callout)
                    Spacer()
                    TextField("", value: Binding(
                        get: { doc.stack.rotateDegrees },
                        set: { newValue in
                            doc.stack.rotateDegrees = max(-180, min(180, newValue))
                        }
                    ), formatter: Self.formatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { doc.stack.rotateDegrees },
                    set: { v in
                        doc.stack.rotateDegrees = (v * 100).rounded() / 100
                    }
                ), in: -180...180)
            }

            HStack(spacing: 8) {
                Button {
                    doc.stack.flipHorizontal.toggle()
                } label: {
                    Label { Text(t("Orizontal")) } icon: {
                        IconifyImage(name: "flip-h", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(doc.stack.flipHorizontal ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                Button {
                    doc.stack.flipVertical.toggle()
                } label: {
                    Label { Text(t("Vertical")) } icon: {
                        IconifyImage(name: "flip-v", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(doc.stack.flipVertical ? Color.accentColor.opacity(0.18) : Color.clear)
                )
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(t("Stare"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(String(format: "Rotire: %.2f°", doc.stack.rotateDegrees))
                        .font(.callout)
                        .monospacedDigit()
                    if doc.stack.flipHorizontal {
                        Text("• Flip H")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                    if doc.stack.flipVertical {
                        Text("• Flip V")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) { cancel() }
                Spacer()
                Button(t("Aplica")) { apply() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasPendingChanges)
            }

            Button {
                doc.stack.rotateDegrees = 0
                doc.stack.flipHorizontal = false
                doc.stack.flipVertical = false
            } label: {
                Text(t("Reseteaza rotire / flip"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(abs(doc.stack.rotateDegrees) < 0.0001
                      && !doc.stack.flipHorizontal
                      && !doc.stack.flipVertical)
            .padding(.top, 4)
        }
        .onAppear {
            if preToolSnap == nil { preToolSnap = doc.stack }
        }
        .onDisappear {
            if let snap = preToolSnap, snap != doc.stack {
                doc.commitSnapshot(snap)
            }
            preToolSnap = nil
        }
    }

    private var hasPendingChanges: Bool {
        guard let snap = preToolSnap else { return false }
        return snap != doc.stack
    }

    private func apply() {
        if let snap = preToolSnap, snap != doc.stack {
            doc.commitSnapshot(snap)
        }
        preToolSnap = doc.stack
    }

    private func cancel() {
        if let snap = preToolSnap {
            doc.stack = snap
        }
        preToolSnap = nil
        tool = .hand
    }

    private func rotate(by delta: Double) {
        var r = doc.stack.rotateDegrees + delta
        while r > 180 { r -= 360 }
        while r <= -180 { r += 360 }
        doc.stack.rotateDegrees = r
    }
}

struct TuneInspector: View {
    @ObservedObject var doc: OpenImage
    @Binding var tool: EditorTool
    @State private var preToolSnap: EditStack?
    @State private var histogramMode: HistogramMode = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Histogram with channel-mode picker.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t("Histograma"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $histogramMode) {
                        ForEach(HistogramMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                HistogramView(histogram: histogram(for: doc.displayImage),
                              mode: histogramMode)
            }
            Divider().padding(.vertical, 2)

            AdjustmentSlider(
                label: t(t("Luminozitate")),
                value: Binding(
                    get: { doc.stack.adjustments.brightness },
                    set: { doc.stack.adjustments.brightness = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: t(t("Contrast")),
                value: Binding(
                    get: { doc.stack.adjustments.contrast },
                    set: { doc.stack.adjustments.contrast = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: t(t("Saturatie")),
                value: Binding(
                    get: { doc.stack.adjustments.saturation },
                    set: { doc.stack.adjustments.saturation = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: t(t("Expunere")),
                value: Binding(
                    get: { doc.stack.adjustments.exposure },
                    set: { doc.stack.adjustments.exposure = $0 }
                ),
                range: -3...3,
                unit: " EV"
            )

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) { cancel() }
                Spacer()
                Button(t("Aplica")) { apply() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasPendingChanges)
            }

            Button {
                doc.stack.adjustments.reset()
            } label: {
                Text(t("Reseteaza ajustarile"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(doc.stack.adjustments.isNeutral)
            .padding(.top, 4)
        }
        .onAppear {
            if preToolSnap == nil { preToolSnap = doc.stack }
        }
        .onDisappear {
            // User left the tool without explicit Apply/Cancel: implicit apply
            // so their edits survive in history.
            if let snap = preToolSnap, snap != doc.stack {
                doc.commitSnapshot(snap)
            }
            preToolSnap = nil
        }
    }

    private var hasPendingChanges: Bool {
        guard let snap = preToolSnap else { return false }
        return snap != doc.stack
    }

    private func apply() {
        if let snap = preToolSnap, snap != doc.stack {
            doc.commitSnapshot(snap)
        }
        preToolSnap = doc.stack  // new baseline; stay in tool
    }

    private func cancel() {
        if let snap = preToolSnap {
            doc.stack = snap
        }
        preToolSnap = nil
        tool = .hand
    }

    private func histogram(for image: NSImage) -> Histogram {
        guard let ci = ImageRenderer.makeCIImage(from: image) else {
            return .empty
        }
        return HistogramComputer.compute(from: ci) ?? .empty
    }
}

struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var onBeginEdit: () -> Void = {}
    var onEndEdit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(displayValue)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Slider(value: $value, in: range) { editing in
                    if editing { onBeginEdit() } else { onEndEdit() }
                }
                Button {
                    // Single-shot reset is itself an action: snapshot + set.
                    onBeginEdit()
                    value = 0
                    onEndEdit()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(value == 0 ? .tertiary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Reseteaza \(label)")
                .disabled(value == 0)
            }
        }
    }

    private var displayValue: String {
        if abs(unit.isEmpty ? value * 100 : value) < 0.01 { return "0\(unit)" }
        if unit.isEmpty {
            return String(format: "%+d", Int((value * 100).rounded()))
        }
        return String(format: "%+.2f\(unit)", value)
    }
}

struct RecentMenu: View {
    @ObservedObject private var recents = RecentFiles.shared

    var body: some View {
        Menu(t("Deschide recente")) {
            if recents.urls.isEmpty {
                Text(t("Niciun fisier recent")).foregroundStyle(.secondary)
            } else {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        WorkspaceHolder.shared.workspace.open(url: url)
                    }
                }
                Divider()
                Button(t("Goleste lista")) { recents.clear() }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recents = RecentFiles.shared

    var body: some View {
        ScrollView {
            settingsForm
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var settingsForm: some View {
        Form {
            Section(t("Vizualizare")) {
                Picker(t("Zoom initial la deschidere"), selection: Binding(
                    get: { settings.initialZoomMode },
                    set: { settings.initialZoomMode = $0 }
                )) {
                    ForEach(InitialZoom.allCases) { z in
                        Text(z.label).tag(z)
                    }
                }
                Toggle(t("Re-aplica modul la redimensionarea ferestrei"),
                       isOn: Binding(
                            get: { settings.alwaysRefitOnResize },
                            set: { settings.alwaysRefitOnResize = $0 }
                       ))
                Text(t("Cand e bifat, la fiecare redimensionare imaginea revine la modul de vizualizare ales, chiar daca ai pannat/zoomat manual."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(t("Fisiere recente")) {
                Stepper(value: Binding(
                    get: { settings.maxRecentItems },
                    set: { newVal in
                        settings.maxRecentItems = newVal
                        recents.trim(to: newVal)
                    }
                ), in: 1...50) {
                    Text(t("Numar maxim: %d", settings.maxRecentItems))
                }
                Button(t("Goleste lista")) { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
            Section(t("Istoric (undo / redo)")) {
                Stepper(value: Binding(
                    get: { settings.maxUndoLevels },
                    set: { settings.maxUndoLevels = $0 }
                ), in: 1...500) {
                    Text(t("Numar maxim de actiuni: %d", settings.maxUndoLevels))
                }
                Text(t("Slider-ele coaleseaza un drag complet intr-o singura actiune."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(t("Limba")) {
                Picker(t("Limba aplicatiei"), selection: Binding(
                    get: { LanguageManager.shared.choice },
                    set: { LanguageManager.shared.choice = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

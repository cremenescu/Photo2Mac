// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    // Annotation tools (text, arrow, rectangle, blur) come after v0.3.0; their
    // icons stay in the bundle, but there is no tool to show until they work.
    case hand, crop, rotate, tune, resize, info
    var id: String { rawValue }
    var iconName: String { rawValue }
    var label: String {
        switch self {
        case .hand: return t("Mutare")
        case .crop: return t("Decupare")
        case .rotate: return t("Rotire")
        case .tune: return t("Ajustari")
        case .resize: return t("Redimensionare")
        case .info: return t("Metadate")
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared
    @State private var zoom: CGFloat = 1.0
    @State private var showInspector: Bool = true
    @State private var forceFitNonce: Int = 0

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
                                            tool: workspace.tool,
                                            comparing: workspace.comparing,
                                            viewportSize: proxy.size,
                                            forceFitNonce: forceFitNonce,
                                            alwaysRefitOnResize: settings.alwaysRefitOnResize)
                        } else {
                            EmptyWorkspaceView()
                        }
                    }
                }
                .frame(minWidth: 240, minHeight: 200)
                .layoutPriority(1)

                if showInspector {
                    InspectorView(zoom: $zoom)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                }
            }
        }
        .onOpenURL { url in
            workspace.open(url: url)
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
                        workspace.tool = t
                    } label: {
                        IconifyImage(name: t.iconName, size: 18)
                            .foregroundStyle(workspace.tool == t ? Color.accentColor : Color.primary)
                    }
                    .help(t.label)
                    .disabled(workspace.selected == nil && t != .hand)
                }

                Divider()

                UndoRedoButtons(doc: workspace.selected)
                EditsListButton(doc: workspace.selected)
                CompareButton(doc: workspace.selected)
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
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var doc: OpenImage
    @Binding var zoom: CGFloat
    let initialZoomMode: InitialZoom
    let tool: EditorTool
    let comparing: Bool
    let viewportSize: CGSize
    let forceFitNonce: Int
    let alwaysRefitOnResize: Bool

    /// While cropping, the canvas shows the image with flip/rotate/adjustments
    /// applied but the crop left out, so a new region is picked on the
    /// ALREADY ROTATED / FLIPPED image. Holding "before/after" shows the
    /// untouched original instead.
    private var imageToShow: NSImage {
        if comparing { return doc.originalImage }
        if let s = doc.cropEdit { return s.preCropImage }
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
                        cropEditState: comparing ? nil : doc.cropEdit,
                        onRotate: { delta in
                            // Trackpad rotate (Rotate tool only): accumulate
                            // into the live angle, clamped, rounded to 0.01°.
                            let r = max(-180, min(180,
                                doc.stack.rotateDegrees + Double(delta)))
                            doc.stack.rotateDegrees = (r * 100).rounded() / 100
                        },
                        onKey: { key in
                            switch key {
                            case .apply:
                                guard tool == .crop || tool == .rotate
                                        || tool == .tune || tool == .resize else { return false }
                                workspace.applyTool()
                            case .cancel:
                                guard tool != .hand else { return false }
                                workspace.cancelTool()
                            case .previous:
                                workspace.openSibling(offset: -1)
                            case .next:
                                workspace.openSibling(offset: 1)
                            case .compare(let down):
                                workspace.comparing = down
                            }
                            return true
                        })
    }
}

/// Press and hold to see the original; release to return to the edit.
struct CompareButton: View {
    @EnvironmentObject var workspace: Workspace
    let doc: OpenImage?

    var body: some View {
        IconifyImage(name: "compare", size: 18)
            .foregroundStyle(workspace.comparing ? Color.accentColor : Color.primary)
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
            .opacity(doc == nil ? 0.35 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if doc != nil, !workspace.comparing { workspace.comparing = true }
                    }
                    .onEnded { _ in workspace.comparing = false }
            )
            .help(t("Tine apasat pentru original (sau tasta \\)"))
            .accessibilityLabel(t("Inainte / dupa"))
            .accessibilityAddTraits(.isButton)
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
    @ObservedObject var doc: OpenImage
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Unsaved edits, as in the Finder-style document close buttons.
            Circle()
                .fill(doc.isDirty ? Color.primary.opacity(0.7) : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityLabel(doc.isDirty ? t("Modificari nesalvate") : "")
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
    @Binding var zoom: CGFloat

    var body: some View {
        let tool = workspace.tool
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
                        TuneInspector(doc: doc)
                    } else {
                        Text(t("Deschide o imagine pentru a ajusta."))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .rotate:
                    if let doc = workspace.selected {
                        RotateInspector(doc: doc, zoom: $zoom)
                    } else {
                        Text(t("Deschide o imagine pentru rotire."))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .crop:
                    if let doc = workspace.selected {
                        CropInspector(doc: doc)
                    } else {
                        Text(t("Deschide o imagine pentru decupare."))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .resize:
                    if let doc = workspace.selected {
                        ResizeInspector(doc: doc)
                    } else {
                        Text(t("Deschide o imagine pentru redimensionare."))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .info:
                    if let doc = workspace.selected {
                        MetadataInspector(doc: doc)
                    } else {
                        Text(t("Deschide o imagine pentru a vedea metadatele."))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
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
                    OutputSizeRow(doc: doc)
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

private struct CropInspectorActive: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var state: CropEditState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) { workspace.cancelTool() }
                Spacer()
                Button(t("Aplica")) { workspace.applyTool() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.hasChanges)
            }

            Button {
                state.aspect = .free
                state.rect = CGRect(origin: .zero, size: state.imageSize)
            } label: {
                Text(t("Reseteaza"))
                    .frame(maxWidth: .infinity)
            }
            .help(t("Reseteaza dreptunghiul la imaginea intreaga"))
            .padding(.top, 4)
        }
    }
}

struct CropInspector: View {
    @ObservedObject var doc: OpenImage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Trage colturile sau muchiile dreptunghiului. Click in interior pentru a-l muta."))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let state = doc.cropEdit {
                // Sub-view observes state directly so rect/aspect changes
                // refresh the Apply disabled state and rect readout live.
                CropInspectorActive(state: state)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct RotateInspector: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var doc: OpenImage
    @Binding var zoom: CGFloat

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
                    doc.stack.rotateQuarter(clockwise: false)
                } label: {
                    Label { Text("-90°") } icon: {
                        IconifyImage(name: "rotate-left", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                Button {
                    doc.stack.rotateQuarter(clockwise: true)
                } label: {
                    Label { Text("+90°") } icon: {
                        IconifyImage(name: "rotate-right", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            // Fine rotation: -180 .. +180 in 0.01° steps.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t("Unghi (°)"))
                        .font(.callout)
                    Spacer()
                    HoldRepeatButton(systemImage: "chevron.left") { step in
                        nudgeAngle(by: -step)
                    }
                    TextField("", value: Binding(
                        get: { doc.stack.rotateDegrees },
                        set: { newValue in
                            doc.stack.rotateDegrees = max(-180, min(180, newValue))
                        }
                    ), formatter: Self.formatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    HoldRepeatButton(systemImage: "chevron.right") { step in
                        nudgeAngle(by: step)
                    }
                }
                Slider(value: Binding(
                    get: { doc.stack.rotateDegrees },
                    set: { v in
                        doc.stack.rotateDegrees = (v * 100).rounded() / 100
                    }
                ), in: -180...180)
                Text(t("Sau roteste cu doua degete pe trackpad."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    doc.stack.flipDisplayHorizontal()
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
                    doc.stack.flipDisplayVertical()
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
                        Text(t("• Flip H"))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                    if doc.stack.flipVertical {
                        Text(t("• Flip V"))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) { workspace.cancelTool() }
                Spacer()
                Button(t("Aplica")) { workspace.applyTool() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!doc.sessionHasChanges)
            }

            Button {
                doc.stack.resetGeometry()
            } label: {
                Text(t("Reseteaza rotire / flip"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(abs(doc.stack.rotateDegrees) < 0.0001
                      && !doc.stack.flipHorizontal
                      && !doc.stack.flipVertical)
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            // Pinch-zoom is disabled while rotating (it competes with the
            // trackpad rotate gesture), so offer an explicit zoom slider here.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t("Zoom"))
                        .font(.callout)
                    Spacer()
                    Text(verbatim: String(format: "%d%%", Int((zoom * 100).rounded())))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button {
                        zoom = max(0.05, (zoom / 1.25 * 100).rounded() / 100)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    Slider(value: Binding(
                        get: { Double(zoom) },
                        set: { zoom = CGFloat($0) }
                    ), in: 0.05...16)
                    Button {
                        zoom = min(16, (zoom * 1.25 * 100).rounded() / 100)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Incremental nudge from the stepper arrows. Clamps to [-180, 180]
    /// (no wrap-around — for straightening you don't want -180 to jump to
    /// +180). Rounds to 0.01° to keep the field clean.
    private func nudgeAngle(by delta: Double) {
        let r = max(-180, min(180, doc.stack.rotateDegrees + delta))
        doc.stack.rotateDegrees = (r * 100).rounded() / 100
    }
}

/// A small arrow button that fires once on tap and, when held, repeats with
/// gradual acceleration — slow at first, then faster (capped so it never runs
/// away). The closure receives the step magnitude to apply for each tick.
struct HoldRepeatButton: View {
    let systemImage: String
    let onStep: (Double) -> Void

    @State private var holding = false
    @State private var tick = 0
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(holding ? Color.accentColor.opacity(0.25)
                          : (hovering ? Color.secondary.opacity(0.18)
                             : Color.secondary.opacity(0.10)))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !holding { startHolding() }
                    }
                    .onEnded { _ in stopHolding() }
            )
            .accessibilityLabel(systemImage.contains("left")
                                ? t("Scade unghiul") : t("Creste unghiul"))
    }

    private func startHolding() {
        holding = true
        tick = 0
        onStep(stepAmount())   // immediate feedback on press
        tick += 1
        scheduleNext()
    }

    private func stopHolding() {
        holding = false
    }

    private func scheduleNext() {
        let interval = currentInterval()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            guard holding else { return }
            onStep(stepAmount())
            tick += 1
            scheduleNext()
        }
    }

    /// Fire rate accelerates with hold duration but floors so it stays usable.
    private func currentInterval() -> Double {
        // 0.32s at first, easing down to a 0.06s floor.
        max(0.06, 0.32 - Double(tick) * 0.03)
    }

    /// Step magnitude grows the longer you hold: fine taps, then coarse sweep.
    private func stepAmount() -> Double {
        switch tick {
        case 0..<8:   return 0.1   // first ~2s: precise
        case 8..<22:  return 0.5
        default:      return 1.0   // sustained hold: faster, but capped
        }
    }
}

struct TuneInspector: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var doc: OpenImage
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
                HistogramView(histogram: doc.histogram, mode: histogramMode)
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
                Button(t("Anuleaza")) { workspace.cancelTool() }
                Spacer()
                Button(t("Aplica")) { workspace.applyTool() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!doc.sessionHasChanges)
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
    }

}

/// Final size of the image. Writes `EditStack.resize` live; the tool session
/// turns the whole visit into one undo step.
struct ResizeInspector: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var doc: OpenImage
    @State private var usePercent = false

    private static let pixelFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 100_000
        f.allowsFloats = false
        return f
    }()

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 1
        f.maximum = 1000
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f
    }()

    /// The image as the stack produces it before resizing.
    private var base: CGSize {
        EditGeometry.sizeBeforeResize(for: doc.stack, sourceSize: doc.originalImage.size)
    }

    private var output: CGSize {
        EditGeometry.outputSize(for: doc.stack, sourceSize: doc.originalImage.size)
    }

    private var keepsAspect: Bool { doc.stack.resize?.keepsAspect ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $usePercent) {
                Text(t("Pixeli")).tag(false)
                Text(t("Procent")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if usePercent {
                HStack {
                    Text(t("Scara"))
                        .font(.callout)
                    Spacer()
                    TextField("", value: Binding(
                        get: { base.width > 0 ? Double(output.width / base.width * 100) : 100 },
                        set: { setPercent($0) }
                    ), formatter: Self.percentFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    Text(verbatim: "%")
                }
            } else {
                HStack(spacing: 6) {
                    Text(t("Latime"))
                        .font(.callout)
                    Spacer()
                    TextField("", value: Binding(
                        get: { Int(output.width) },
                        set: { setWidth($0) }
                    ), formatter: Self.pixelFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    Text(verbatim: "px")
                }
                HStack(spacing: 6) {
                    Text(t("Inaltime"))
                        .font(.callout)
                    Spacer()
                    TextField("", value: Binding(
                        get: { Int(output.height) },
                        set: { setHeight($0) }
                    ), formatter: Self.pixelFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    Text(verbatim: "px")
                }
                Toggle(t("Pastreaza proportiile"), isOn: Binding(
                    get: { keepsAspect },
                    set: { setKeepsAspect($0) }
                ))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t("Latura lunga"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([1920, 1200, 800], id: \.self) { n in
                        Button("\(n)") { setLongEdge(n) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(t("Inainte: %d × %d px", Int(base.width), Int(base.height)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(t("Rezultat: %d × %d px", Int(output.width), Int(output.height)))
                    .font(.callout)
                    .monospacedDigit()
                if output.width > base.width + 0.5 || output.height > base.height + 0.5 {
                    Text(t("Marire: imaginea poate iesi mai putin clara."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if doc.stack.resize?.keepsAspect == true {
                    Text(t("Imaginea incape in %d × %d px; o decupare facuta ulterior nu o deformeaza.",
                           doc.stack.resize?.width ?? 0, doc.stack.resize?.height ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button(t("Anuleaza")) { workspace.cancelTool() }
                Spacer()
                Button(t("Aplica")) { workspace.applyTool() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!doc.sessionHasChanges)
            }

            Button {
                doc.stack.resize = nil
            } label: {
                Text(t("Elimina redimensionarea"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(doc.stack.resize == nil)
            .padding(.top, 4)
        }
    }

    /// Store a target, or nothing when it is the size the image already has.
    private func store(_ spec: ResizeSpec) {
        let result = EditGeometry.resizedSize(spec, from: base)
        if abs(result.width - base.width) < 0.5 && abs(result.height - base.height) < 0.5 {
            doc.stack.resize = nil
        } else {
            doc.stack.resize = spec
        }
    }

    private func setWidth(_ w: Int) {
        guard w > 0, base.width > 0 else { return }
        if keepsAspect {
            let h = max(1, Int((CGFloat(w) * base.height / base.width).rounded()))
            store(ResizeSpec(width: w, height: h, keepsAspect: true))
        } else {
            store(ResizeSpec(width: w, height: Int(output.height), keepsAspect: false))
        }
    }

    private func setHeight(_ h: Int) {
        guard h > 0, base.height > 0 else { return }
        if keepsAspect {
            let w = max(1, Int((CGFloat(h) * base.width / base.height).rounded()))
            store(ResizeSpec(width: w, height: h, keepsAspect: true))
        } else {
            store(ResizeSpec(width: Int(output.width), height: h, keepsAspect: false))
        }
    }

    private func setPercent(_ p: Double) {
        guard p > 0 else { return }
        let w = max(1, Int((base.width * p / 100).rounded()))
        let h = max(1, Int((base.height * p / 100).rounded()))
        store(ResizeSpec(width: w, height: h, keepsAspect: true))
    }

    /// A square box: the long side is `n` whatever the crop becomes later.
    private func setLongEdge(_ n: Int) {
        store(ResizeSpec(width: n, height: n, keepsAspect: true))
    }

    private func setKeepsAspect(_ on: Bool) {
        let out = output
        if on {
            guard base.width > 0 else { return }
            let w = Int(out.width)
            let h = max(1, Int((CGFloat(w) * base.height / base.width).rounded()))
            store(ResizeSpec(width: w, height: h, keepsAspect: true))
        } else {
            store(ResizeSpec(width: Int(out.width), height: Int(out.height), keepsAspect: false))
        }
    }
}

/// "Result: W x H px" under the file size, when the edits change it.
struct OutputSizeRow: View {
    @ObservedObject var doc: OpenImage

    var body: some View {
        let out = EditGeometry.outputSize(for: doc.stack, sourceSize: doc.originalImage.size)
        if Int(out.width) != Int(doc.originalImage.size.width)
            || Int(out.height) != Int(doc.originalImage.size.height) {
            Text(t("Rezultat: %d × %d px", Int(out.width), Int(out.height)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
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
            Section(t("Salvare")) {
                Picker(t("Cand salvezi peste fisier (Cmd+S)"), selection: Binding(
                    get: { settings.saveMode },
                    set: { settings.saveMode = $0 }
                )) {
                    ForEach(SaveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Text(settings.saveMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.saveMode == .sidecar {
                    Text(t("Atentie: cu aceasta setare, imaginea trimisa prin e-mail sau vazuta in Finder este cea NEEDITATA."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(t("Setarea decide cum se scriu fisierele de acum incolo. Fisierele deja salvate se citesc dupa cum au fost scrise, deci poti schimba modul oricand fara sa strici ce ai salvat."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            fileAssociationsSection
        }
        .formStyle(.grouped)
        .padding()
    }

    // Bumped by the bulk button to ask all rows to poll. NOT applied via
    // `.id()` on the section — that would destroy child @State and kill
    // each row's polling Task. Rows observe it via `.onChange`.
    @State private var bulkRefreshNonce = 0

    private var fileAssociationsSection: some View {
        Section(t("Asociere tipuri de fisiere")) {
            ForEach(FileAssociations.supportedTypes) { type in
                FileAssociationRow(type: type, bulkRefreshNonce: bulkRefreshNonce)
            }
            Button(t("Seteaza Photo2Mac default pentru toate cele de mai sus")) {
                for type in FileAssociations.supportedTypes {
                    FileAssociations.makeUsDefault(for: type.id)
                }
                bulkRefreshNonce &+= 1
            }
            Text(t("macOS poate cere o singura confirmare la prima schimbare. Pentru a reveni la aplicatia anterioara, foloseste Finder > Get Info > Open With."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One row of the File Associations section. Keeps its own snapshot of the
/// current default handler. macOS shows a confirmation dialog ("Use
/// Photo2Mac" vs "Keep Preview") asynchronously after our call, so the
/// real outcome lands later — we poll for it.
private struct FileAssociationRow: View {
    let type: FileAssociations.ImageType
    let bulkRefreshNonce: Int      // bump from parent = please poll

    @State private var currentBundleID: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(type.label).fontWeight(.medium)
                    Text(type.extensions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let bid = currentBundleID, !isOurs {
                    Text(t("Default: %@",
                          FileAssociations.displayName(forBundleID: bid)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isOurs {
                    Text(t("Default: Photo2Mac"))
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(t("Default: (nesetat)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Plain button row, NOT a SwiftUI Toggle. macOS shows its
            // confirmation sheet asynchronously after our LS call and the
            // user may reject the change — a toggle would visually flip
            // before that decision lands, then mismatch reality. A button
            // doesn't carry implied state.
            if isOurs {
                Button(t("Reseteaza")) {
                    FileAssociations.setDefault(
                        FileAssociations.fallbackBundleID, for: type.id)
                    startPollingForChange()
                }
            } else {
                Button(t("Seteaza default")) {
                    FileAssociations.makeUsDefault(for: type.id)
                    startPollingForChange()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { refresh() }
        .onChange(of: bulkRefreshNonce) { _ in startPollingForChange() }
        .onDisappear { pollTask?.cancel() }
    }

    private var isOurs: Bool {
        currentBundleID?.lowercased()
            == FileAssociations.ourBundleID.lowercased()
    }

    private func refresh() {
        currentBundleID = FileAssociations.currentDefaultHandler(for: type.id)
    }

    /// macOS shows a "Use Photo2Mac / Keep Preview" sheet after our call.
    /// `LSSetDefaultRoleHandlerForContentType` returns BEFORE that dialog
    /// is shown, so reading the DB immediately gives the old value. We
    /// poll for a few seconds; once a tick reports a stable value the
    /// toggle reflects the real outcome (including when the user pressed
    /// "Keep Preview" and we have to snap back).
    private func startPollingForChange() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Delays in ms — short ones in case the user clicks fast,
            // longer ones to cover slow taps; total window ~10 s.
            for delayMs in [150, 250, 400, 700, 1100, 1800, 2500, 3500] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                if Task.isCancelled { return }
                refresh()
            }
        }
    }
}

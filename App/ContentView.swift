// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    case hand, crop, rotate, tune, text, arrow, rect, blur
    var id: String { rawValue }
    var iconName: String { rawValue }
    var label: String {
        switch self {
        case .hand: return "Mutare"
        case .crop: return "Decupare"
        case .rotate: return "Rotire"
        case .tune: return "Ajustari"
        case .text: return "Text"
        case .arrow: return "Sageata"
        case .rect: return "Dreptunghi"
        case .blur: return "Blur"
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
                    InspectorView(tool: tool, cropHolder: cropEdit)
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
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    zoom = max(0.05, zoom / 1.25)
                } label: { IconifyImage(name: "zoom-out", size: 16) }
                .help("Micsoreaza")
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
                .help("Mareste")
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
                .help("Mod vizualizare")
                .disabled(workspace.selected == nil)

                Toggle(isOn: $showInspector) {
                    IconifyImage(name: "inspector", size: 16)
                }
                .help("Inspector")
            }
        }
    }
}

/// Observes the OpenImage so re-renders (slider live updates) propagate.
/// WorkspaceView only observes `Workspace`, not the individual document.
struct CanvasContainer: View {
    @ObservedObject var doc: OpenImage
    @Binding var zoom: CGFloat
    let initialZoomMode: InitialZoom
    let tool: EditorTool
    let viewportSize: CGSize
    let forceFitNonce: Int
    let alwaysRefitOnResize: Bool
    let cropEditState: CropEditState?

    /// When crop tool is active, show the ORIGINAL image (not the
    /// already-cropped displayImage) so the user can draw a fresh crop on the
    /// full canvas. When Apply commits, the new crop replaces stack.crop.
    private var imageToShow: NSImage {
        cropEditState != nil ? doc.originalImage : doc.displayImage
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

    var body: some View {
        VStack(spacing: 16) {
            IconifyImage(name: "hand", size: 64)
                .foregroundStyle(.secondary)
                .opacity(0.4)
            Text("Workspace gol")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Trage o imagine aici, sau Cmd+O.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Deschide imagine...") {
                workspace.openPanel()
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InspectorView: View {
    @EnvironmentObject var workspace: Workspace
    let tool: EditorTool
    let cropHolder: CropEditHolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.label)
                .font(.headline)

            Divider()

            Group {
                switch tool {
                case .hand:
                    Text("Click-drag pentru a misca imaginea in workspace. Trackpad: scroll pentru pan, pinch pentru zoom.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .tune:
                    if let doc = workspace.selected {
                        TuneInspector(doc: doc)
                    } else {
                        Text("Deschide o imagine pentru a ajusta.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .rotate:
                    if let doc = workspace.selected {
                        RotateInspector(doc: doc)
                    } else {
                        Text("Deschide o imagine pentru rotire.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                case .crop:
                    if let doc = workspace.selected {
                        CropInspector(doc: doc, holder: cropHolder)
                    } else {
                        Text("Deschide o imagine pentru decupare.")
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
                    Text("Fisier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(doc.displayName)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("Dimensiune")
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
            Text("Raport")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trage colturile sau muchiile dreptunghiului. Click in interior pentru a-l muta.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let state = holder.state {
                AspectPicker(state: state)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Dreptunghi (pixeli)")
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
                Button("Anuleaza") {
                    cancelCrop()
                }
                Spacer()
                Button("Aplica") {
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
                Text("Reseteaza")
                    .frame(maxWidth: .infinity)
            }
            .help("Reseteaza dreptunghiul la imaginea intreaga")
            .padding(.top, 4)
        }
        .onAppear {
            ensureCropState()
        }
    }

    private func ensureCropState() {
        if holder.state == nil {
            holder.state = CropEditState(imageSize: doc.originalImage.size,
                                          currentCrop: doc.stack.crop)
            // While editing, render the original (so the user sees the whole
            // image and can choose any new crop region).
            doc.stack.crop = nil
        }
    }

    private func applyCrop() {
        guard let s = holder.state else { return }
        let n = s.normalized
        // Treat "full image" as no crop.
        if abs(n.x) < 0.001 && abs(n.y) < 0.001 &&
            abs(n.width - 1) < 0.001 && abs(n.height - 1) < 0.001 {
            doc.stack.crop = nil
        } else {
            doc.stack.crop = n
        }
        holder.state = nil
    }

    private func cancelCrop() {
        // Restore the original crop value if it had been set, then exit crop mode.
        if let s = holder.state {
            doc.stack.crop = s.originalStackCrop
        }
        holder.state = nil
    }
}

struct RotateInspector: View {
    @ObservedObject var doc: OpenImage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    rotate(by: -90)
                } label: {
                    Label {
                        Text("-90°")
                    } icon: {
                        IconifyImage(name: "rotate-left", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                Button {
                    rotate(by: 90)
                } label: {
                    Label {
                        Text("+90°")
                    } icon: {
                        IconifyImage(name: "rotate-right", size: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            HStack(spacing: 8) {
                Button {
                    doc.stack.flipHorizontal.toggle()
                } label: {
                    Label {
                        Text("Orizontal")
                    } icon: {
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
                    Label {
                        Text("Vertical")
                    } icon: {
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
                Text("Stare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("Rotire: \(doc.stack.rotateDegrees)°")
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

            HStack {
                Spacer()
                Button("Reseteaza") {
                    doc.stack.rotateDegrees = 0
                    doc.stack.flipHorizontal = false
                    doc.stack.flipVertical = false
                }
                .disabled(doc.stack.rotateDegrees == 0
                          && !doc.stack.flipHorizontal
                          && !doc.stack.flipVertical)
            }
            .padding(.top, 4)
        }
    }

    private func rotate(by delta: Int) {
        var r = doc.stack.rotateDegrees + delta
        // Normalize to [0, 360)
        r = ((r % 360) + 360) % 360
        doc.stack.rotateDegrees = r
    }
}

struct TuneInspector: View {
    @ObservedObject var doc: OpenImage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdjustmentSlider(
                label: "Luminozitate",
                value: Binding(
                    get: { doc.stack.adjustments.brightness },
                    set: { doc.stack.adjustments.brightness = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: "Contrast",
                value: Binding(
                    get: { doc.stack.adjustments.contrast },
                    set: { doc.stack.adjustments.contrast = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: "Saturatie",
                value: Binding(
                    get: { doc.stack.adjustments.saturation },
                    set: { doc.stack.adjustments.saturation = $0 }
                ),
                range: -1...1
            )
            AdjustmentSlider(
                label: "Expunere",
                value: Binding(
                    get: { doc.stack.adjustments.exposure },
                    set: { doc.stack.adjustments.exposure = $0 }
                ),
                range: -3...3,
                unit: " EV"
            )

            HStack {
                Spacer()
                Button("Reseteaza") {
                    doc.stack.adjustments.reset()
                }
                .disabled(doc.stack.adjustments.isNeutral)
            }
            .padding(.top, 6)
        }
    }
}

struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""

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
                Slider(value: $value, in: range) { _ in }
                Button {
                    value = 0
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
        Menu("Deschide recente") {
            if recents.urls.isEmpty {
                Text("Niciun fisier recent").foregroundStyle(.secondary)
            } else {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        WorkspaceHolder.shared.workspace.open(url: url)
                    }
                }
                Divider()
                Button("Goleste lista") { recents.clear() }
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
            Section("Vizualizare") {
                Picker("Zoom initial la deschidere", selection: Binding(
                    get: { settings.initialZoomMode },
                    set: { settings.initialZoomMode = $0 }
                )) {
                    ForEach(InitialZoom.allCases) { z in
                        Text(z.label).tag(z)
                    }
                }
                Toggle("Re-aplica modul la redimensionarea ferestrei",
                       isOn: Binding(
                            get: { settings.alwaysRefitOnResize },
                            set: { settings.alwaysRefitOnResize = $0 }
                       ))
                Text("Cand e bifat, la fiecare redimensionare imaginea revine la modul de vizualizare ales, chiar daca ai pannat/zoomat manual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Fisiere recente") {
                Stepper(value: Binding(
                    get: { settings.maxRecentItems },
                    set: { newVal in
                        settings.maxRecentItems = newVal
                        recents.trim(to: newVal)
                    }
                ), in: 1...50) {
                    Text("Numar maxim: \(settings.maxRecentItems)")
                }
                Button("Goleste lista") { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

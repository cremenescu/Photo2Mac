// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case hand, crop, rotate, text, arrow, rect, blur
    var id: String { rawValue }
    var iconName: String { rawValue }
    var label: String {
        switch self {
        case .hand: return "Mutare"
        case .crop: return "Decupare"
        case .rotate: return "Rotire"
        case .text: return "Text"
        case .arrow: return "Sageata"
        case .rect: return "Dreptunghi"
        case .blur: return "Blur"
        }
    }
}

struct ContentView: View {
    @ObservedObject var document: PhotoDocument
    @ObservedObject private var settings = AppSettings.shared
    @State private var tool: EditorTool = .hand
    @State private var zoom: CGFloat = 1.0
    @State private var showInspector: Bool = true

    var body: some View {
        HSplitView {
            ImageCanvasView(image: document.image,
                            zoom: $zoom,
                            initialZoomMode: settings.initialZoomMode)
                .frame(minWidth: 500, minHeight: 400)
                .layoutPriority(1)

            if showInspector {
                InspectorView(document: document, tool: tool)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
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
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    zoom = max(0.05, zoom / 1.25)
                } label: { IconifyImage(name: "zoom-out", size: 16) }
                .help("Micsoreaza")

                Text("\(Int(zoom * 100))%")
                    .frame(width: 48)
                    .monospacedDigit()

                Button {
                    zoom = min(16, zoom * 1.25)
                } label: { IconifyImage(name: "zoom-in", size: 16) }
                .help("Mareste")

                Button {
                    zoom = 1.0
                } label: { IconifyImage(name: "zoom-actual", size: 16) }
                .help("Marime reala (100%)")

                Toggle(isOn: $showInspector) {
                    IconifyImage(name: "inspector", size: 16)
                }
                .help("Inspector")
            }
        }
    }
}

struct InspectorView: View {
    @ObservedObject var document: PhotoDocument
    let tool: EditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.label)
                .font(.headline)

            Divider()

            switch tool {
            case .hand:
                Text("Tine apasat pentru a misca imaginea in workspace. Trackpad: scroll pentru pan, pinch pentru zoom.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            default:
                Text("Parametri \(tool.label) — in dezvoltare")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            if let img = document.image {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dimensiune")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(img.size.width)) x \(Int(img.size.height)) px")
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
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
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

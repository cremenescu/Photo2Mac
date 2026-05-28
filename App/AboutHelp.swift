// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit

// MARK: - About panel

enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        let credits = NSMutableAttributedString()
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        credits.append(NSAttributedString(
            string: "\(t("Editor de imagini nativ macOS, model nedistructiv (XMP).")) \n\n",
            attributes: small))

        // Project + author links.
        let gh = NSMutableAttributedString(string: "GitHub: ", attributes: small)
        gh.append(linkAttr("github.com/cremenescu/Photo2Mac",
                            url: "https://github.com/cremenescu/Photo2Mac"))
        credits.append(gh)
        credits.append(NSAttributedString(string: "\n", attributes: small))

        let issues = NSMutableAttributedString(string: "\(t("Probleme")): ", attributes: small)
        issues.append(linkAttr("github.com/cremenescu/Photo2Mac/issues",
                                url: "https://github.com/cremenescu/Photo2Mac/issues"))
        credits.append(issues)
        credits.append(NSAttributedString(string: "\n", attributes: small))

        let mail = NSMutableAttributedString(string: "E-mail: ", attributes: small)
        mail.append(linkAttr("razvan@cremenescu.ro",
                              url: "mailto:razvan@cremenescu.ro"))
        credits.append(mail)

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Photo2Mac",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            .init(rawValue: "Copyright"):
                "Copyright (c) 2026 Razvan Cremenescu — GPL-2.0-or-later",
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func linkAttr(_ text: String, url: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: url) as Any,
            .foregroundColor: NSColor.linkColor,
        ])
    }
}

// MARK: - Help window

final class HelpWindow {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = HelpView()
            .environmentObject(LanguageManager.shared)
            .id(LanguageManager.shared.choice)
        let host = NSHostingController(rootView: content)
        // NSHostingController shrinks the window to its content's intrinsic
        // size on first display, which collapses to almost nothing while
        // SwiftUI's ScrollView is still laying out. Pin the preferred size
        // explicitly and bump initial frame so the help is readable on open.
        host.preferredContentSize = NSSize(width: 740, height: 820)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = t("Ajutor Photo2Mac")
        w.contentViewController = host
        w.setContentSize(NSSize(width: 740, height: 820))
        w.center()
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 520)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HelpView: View {
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                section(title: t("Ce este Photo2Mac"), body: [
                    t("Photo2Mac este un editor de imagini nativ macOS, simplu si rapid. Modelul de editare este nedistructiv: pixelii originali nu se modifica decat la salvare; pana atunci, fiecare ajustare (decupare, rotire, flip, luminozitate, contrast, saturatie, expunere) e doar o instructiune in stiva de editari, randata live prin Core Image."),
                    t("Stiva de editari se salveaza in metadata XMP a fisierului — deschiderea aceluiasi fisier in Photo2Mac restaureaza editarile (le poti modifica). Alte aplicatii vad doar pixelii randati.")
                ])
                section(title: t("Cum incepi"), body: [
                    t("File → Open image... (Cmd+O), drag-and-drop pe fereastra, sau alege o imagine recenta din ecranul de pornire."),
                    t("Imaginile deschise apar ca tab-uri in partea de sus. Cmd+W inchide tab-ul curent, Cmd+Shift+W inchide fereastra (app-ul ramane viu).")
                ])
                section(title: t("Tool-uri"), body: [
                    t("Mutare: mut imaginea in workspace (click-drag sau scroll trackpad)."),
                    t("Decupare: dreptunghi de selectie cu colt-handles + edge-handles. Picker pentru raport (Original, 1:1, 4:3, ..., Liber). Apply commit-uieste."),
                    t("Rotire: presets ±90°, slider 0.01° + text field pentru unghi precis, Flip H/V."),
                    t("Ajustari: histograma live (Luminanta/RGB/R/G/B) + sliders pentru Luminozitate, Contrast, Saturatie, Expunere."),
                    t("Metadate: vezi EXIF (camera, ISO, expunere, etc.) si statusul XMP-ului Photo2Mac (JSON brut optional).")
                ])
                section(title: t("Save / persistare"), body: [
                    t("Cmd+S scrie peste fisierul deschis: pixeli randati + stack EditStack ca XMP. macOS retine si o versiune anterioara prin NSFileVersion."),
                    t("Cmd+Shift+S = Save As cu panel."),
                    t("Daca inchizi tab-ul fara save, editarile se pastreaza intr-un autosave invisible (App Support); la reopen primesti prompt pentru a continua sau renunta.")
                ])
                xmpSection
                section(title: t("Scurtaturi"), body: shortcutsList)
                section(title: t("Sfaturi"), body: [
                    t("La Crop, intrarea in tool reduce zoom-ul cu 10% ca sa ai loc sa apuci colturile."),
                    t("La Tune/Rotate, sliderele coaleseaza intr-o singura actiune in stiva undo (Cmd+Z anuleaza intreg drag-ul, nu fiecare pixel)."),
                    t("Butonul Edits din toolbar arata lista de editari aplicate cu X per item pentru revert selectiv.")
                ])
                section(title: t("Limitari curente"), body: [
                    t("Faza 2 (urmatoare): anotari vector (text/sageata/dreptunghi/blur), batch processor, organize/browse, screenshot capture, RAW."),
                    t("Aspect ratio Original = ratio-ul nativ al imaginii curente."),
                    t("CMYK histogram in pauza (cere ICC color management corect).")
                ])
                Divider()
                links
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Photo2Mac")
                    .font(.system(size: 22, weight: .semibold))
                Text(t("Ajutor"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var shortcutsList: [String] {
        [
            "Cmd+O — \(t("deschide imagine"))",
            "Cmd+S — \(t("salveaza peste fisier"))",
            "Cmd+Shift+S — \(t("salveaza ca"))",
            "Cmd+W — \(t("inchide tab"))",
            "Cmd+Shift+W — \(t("inchide fereastra"))",
            "Cmd+Z — \(t("anuleaza ultima actiune"))",
            "Cmd+Shift+Z — \(t("refa"))",
            "Cmd+, — \(t("preferinte"))",
        ]
    }

    @ViewBuilder
    private func section(title: String, body items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var xmpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Formatul XMP"))
                .font(.headline)
            Text(t("Stiva de editari (EditStack) se serializeaza ca JSON intr-o proprietate XMP custom, incorporata in fisierul salvat. Photo2Mac o reciteste la deschidere; alte aplicatii vad doar pixelii randati."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t("Namespace:")).foregroundStyle(.secondary)
                    Text(verbatim: "http://ns.photo2mac.cremenescu.ro/1.0/")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t("Prefix:")).foregroundStyle(.secondary)
                    Text(verbatim: "p2m").font(.system(.callout, design: .monospaced))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t("Property:")).foregroundStyle(.secondary)
                    Text(verbatim: "p2m:editStack").font(.system(.callout, design: .monospaced))
                }
            }
            Text(t("Containere: JPEG (APP1), PNG (iTXt), HEIC (meta box), TIFF (tag 700). Se mai scriu si xmp:CreatorTool + tiff:ImageDescription + dc:description (rezumat in engleza), ca metadata sa fie vizibila in orice viewer (Preview, exiftool, Bridge, Get Info)."))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: """
{
  "rotateDegrees": -2.5,
  "flipHorizontal": false,
  "flipVertical": false,
  "crop": { "x": 0.05, "y": 0.10,
            "width": 0.90, "height": 0.80 },
  "adjustments": {
    "brightness": 0.12, "contrast": 0.05,
    "saturation": 0,    "exposure": 0.30
  }
}
""")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .fixedSize(horizontal: false, vertical: true)
            Text(t("Ordine de randare: flipH → flipV → rotate → crop → adjustments. Crop-ul lucreaza pe cadrul rotit/flipped, ajustarile pe regiunea decupata."))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(t("Documentatie completa (docs/XMP.md)"),
                     destination: URL(string: "https://github.com/cremenescu/Photo2Mac/blob/main/docs/XMP.md")!)
            }
            .font(.callout)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Linkuri")).font(.headline)
            HStack(spacing: 14) {
                Link("GitHub", destination:
                    URL(string: "https://github.com/cremenescu/Photo2Mac")!)
                Link(t("Probleme"), destination:
                    URL(string: "https://github.com/cremenescu/Photo2Mac/issues")!)
                Link("razvan@cremenescu.ro", destination:
                    URL(string: "mailto:razvan@cremenescu.ro")!)
            }
            .font(.callout)
        }
    }
}

// MARK: - Commands

struct AboutHelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(t("Despre Photo2Mac")) { AboutPanel.show() }
        }
        CommandGroup(replacing: .help) {
            Button(t("Ajutor Photo2Mac")) { HelpWindow.shared.show() }
                .keyboardShortcut("?", modifiers: [.command])
            Divider()
            Button(t("Vezi pe GitHub")) {
                if let u = URL(string: "https://github.com/cremenescu/Photo2Mac") {
                    NSWorkspace.shared.open(u)
                }
            }
            Button(t("Raporteaza o problema")) {
                if let u = URL(string: "https://github.com/cremenescu/Photo2Mac/issues/new") {
                    NSWorkspace.shared.open(u)
                }
            }
            Button(t("E-mail autor")) {
                if let u = URL(string: "mailto:razvan@cremenescu.ro") {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }
}

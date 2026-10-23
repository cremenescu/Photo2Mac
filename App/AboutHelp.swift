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
                    t("Photo2Mac este un editor de imagini nativ macOS, simplu si rapid. Editarea e nedistructiva: decuparea, rotirea, oglindirea, ajustarile si redimensionarea sunt pasi intr-o stiva de editari, randata live prin Core Image; pixelii se schimba abia la salvare."),
                    t("Ce face Cmd+S alegi in Preferinte > Salvare: fisierul devine imaginea editata, originalul ramane neatins cu editarile intr-un fisier .p2m alaturi, sau fisierul editat poarta originalul in interior. In ultimele doua cazuri, redeschiderea in Photo2Mac aduce inapoi editarile, pe care le poti modifica.")
                ])
                section(title: t("Cum incepi"), body: [
                    t("Fisier > Deschide imagine... (Cmd+O), trage o imagine pe fereastra sau alege una recenta din ecranul de pornire."),
                    t("Imaginile deschise apar ca taburi; un punct langa nume inseamna modificari nesalvate. Cmd+W inchide tabul, iar inchiderea ultimului tab sau a ferestrei inchide aplicatia. Daca ai modificari nesalvate, esti intrebat inainte."),
                    t("Sagetile stanga / dreapta (dupa un click pe imagine) sau Cmd+[ / Cmd+] deschid imaginea anterioara / urmatoare din acelasi dosar. Tabul curent e inlocuit doar daca nu are modificari nesalvate.")
                ])
                section(title: t("Unelte"), body: [
                    t("Mutare: muti imaginea (click-drag sau scroll pe trackpad), pinch pentru zoom."),
                    t("Decupare: dreptunghi cu manere in colturi si pe laturi, raport fix sau liber. Return aplica, Escape renunta, si cu inspectorul ascuns. Decuparea ramane pe acelasi subiect daca rotesti imaginea dupa aceea."),
                    t("Rotire: ±90°, unghi fin cu pas de 0,01° (slider, camp sau doua degete pe trackpad) si oglindire orizontala / verticala a imaginii asa cum o vezi."),
                    t("Ajustari: histograma live (Luminanta / RGB / R / G / B) si Luminozitate, Contrast, Saturatie, Expunere."),
                    t("Redimensionare: latime si inaltime in pixeli sau procent, cu proportiile pastrate, plus latura lunga 1920 / 1200 / 800. Se aplica ultima, deci o poti schimba sau scoate oricand."),
                    t("Metadate: EXIF (camera, ISO, expunere etc.) si ce a scris Photo2Mac in XMP."),
                    t("Inainte / dupa: tine apasat butonul din toolbar sau tasta \\ ca sa vezi originalul.")
                ])
                section(title: t("Salvare"), body: [
                    t("Cmd+S salveaza peste fisier, in modul ales in Preferinte. macOS pastreaza si versiunea dinainte; o recuperezi deschizand fisierul in Preview, Fisier > Revino la."),
                    t("Cmd+Shift+S salveaza intr-un fisier nou, iar documentul trece pe fisierul nou."),
                    t("Cmd+Shift+E exporta o copie: alegi formatul (JPEG, PNG, HEIC, TIFF), calitatea si o latura maxima. Documentul ramane cum era."),
                    t("Editarile nesalvate sunt pastrate automat. Daca aplicatia se inchide neasteptat, la redeschiderea imaginii esti intrebat daca le continui; daca fisierul s-a schimbat intre timp, nu ti le mai propune.")
                ])
                xmpSection
                section(title: t("Scurtaturi"), body: shortcutsList)
                section(title: t("Sfaturi"), body: [
                    t("In Rotire, Ajustari si Redimensionare, tot ce faci pana la Aplica e un singur pas de undo (Cmd+Z)."),
                    t("Butonul Editari din toolbar arata lista editarilor aplicate; X scoate doar pasul respectiv."),
                    t("La intrarea in Decupare zoom-ul scade cu 10%, ca sa ajungi usor la colturi."),
                    t("Photo2Mac cauta o versiune noua o data pe zi si o instaleaza doar dupa ce accepti. Verificarea se opreste din Preferinte > Actualizari, iar Photo2Mac > Cauta actualizari... o face la cerere.")
                ])
                section(title: t("Limitari curente"), body: [
                    t("Urmeaza: anotari (text, sageata, dreptunghi, blur), procesare in lot, RAW."),
                    t("Salvarea scrie 8 biti pe canal: o imagine de 16 biti pierde adancimea de culoare la salvare."),
                    t("Raportul Original = raportul imaginii asa cum arata dupa rotire.")
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
            "Cmd+Shift+E — \(t("exporta o copie"))",
            "Cmd+W — \(t("inchide tab"))",
            "Cmd+Shift+W — \(t("inchide fereastra"))",
            "Cmd+Z — \(t("anuleaza ultima actiune"))",
            "Cmd+Shift+Z — \(t("refa"))",
            "Cmd+[ / Cmd+], ← / → — \(t("imaginea anterioara / urmatoare din dosar"))",
            "Return / Escape — \(t("aplica / renunta in unealta curenta"))",
            "\\ — \(t("tine apasat: originalul"))",
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
            Text(t("Containere: JPEG (APP1), PNG (iTXt), HEIC (meta box), TIFF (tag 700). Se mai scriu xmp:CreatorTool si dc:description (rezumat in engleza), ca editarile sa se vada in orice viewer (Preview, exiftool, Bridge, Get Info). Alaturi: p2m:saveMode (cum a fost scris fisierul) si, in modul care pastreaza originalul, p2m:originalImage, p2m:originalType si p2m:originalSHA256."))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: """
{
  "rotateDegrees": -2.5,
  "flipHorizontal": false,
  "flipVertical": false,
  "crop": { "x": 0.05, "y": 0.10,
            "width": 0.90, "height": 0.80 },
  "cropBasisDegrees": -2.5,
  "adjustments": {
    "brightness": 0.12, "contrast": 0.05,
    "saturation": 0,    "exposure": 0.30
  },
  "resize": { "width": 1920, "height": 1920,
              "keepsAspect": true }
}
""")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .fixedSize(horizontal: false, vertical: true)
            Text(t("Ordine de randare: flipH → flipV → rotate → crop → adjustments → resize. Crop-ul lucreaza pe cadrul rotit, la unghiul din cropBasisDegrees; ajustarile pe regiunea decupata; resize pe rezultat."))
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
            CheckForUpdatesView()
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

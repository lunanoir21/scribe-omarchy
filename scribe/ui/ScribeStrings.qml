pragma Singleton
import QtQuick

// Every user-visible string, in Turkish and English. ScribeHost sets `lang` from the `ui` setting
// ("auto" follows $LANG), and everything reads `Strings.s.<key>`, so a change applies live.
QtObject {
    id: strings

    property string lang: "en"          // "tr" | "en"
    readonly property var s: lang === "tr" ? tr : en

    readonly property var tr: ({
        // overlay
        dragRegion: "Alanı sürükle      Esc iptal",
        reading: "OKUNUYOR",
        dragHint: "Metni sürükleyerek seç",
        lowConf: function (n) { return "Güven düşük (%" + n + ")  ·  yine de seçebilirsin"; },
        noText: "Metin bulunamadı",
        noLang: "Dil paketi eksik",
        copy: "Kopyala",
        copied: "Kopyalandı",
        selectAll: "Tümünü seç",
        // settings
        settings: "Ayarlar",
        readingLangs: "OKUMA DİLLERİ",
        installed: "kurulu",
        download: "İndir",
        howInstall: function (name) { return name + " nasıl kurulsun?"; },
        direct: "Doğrudan indir",
        directHint: "Parola gerekmez, ev klasörüne iner",
        viaPm: "Paket yöneticisiyle kur",
        asksPassword: "parola ister",
        copyCommand: "Komutu kopyala",
        runTerminal: "Terminalde çalıştır",
        terminalOpen: "Terminal açık, bitince liste yenilenir",
        installInfo: function (pm, os) {
            return "İndir'e basınca iki yol sunulur: parolasız doğrudan indirme ya da " + pm
                + (os ? " (" + os + ")" : "") + " ile kurulum (parola ister).";
        },
        pmFallback: "paket yöneticisi",
        behaviour: "DAVRANIŞ",
        closeAfterCopy: "Kopyalayınca kapat",
        autoCopy: "Okuyunca hepsini kopyala",
        joinLines: "Paragraf satırlarını birleştir",
        highlight: "VURGU RENGİ",
        interfaceLang: "ARAYÜZ DİLİ",
        auto: "Otomatik",
        // host
        missing: function (list) { return "Eksik: " + list; },
        grabFailed: "Ekran görüntüsü alınamadı (grim).",
        readFailed: function (why) { return "Okuma başarısız oldu (" + why + ")."; },
        readTimeout: "Okuma çok uzun sürdü, iptal edildi.",
        terminalClosed: "Terminal kapandı, dil listesi yenilendi.",
        installFailed: "Kurulum başarısız oldu.",
        commandCopied: "Komut kopyalandı, terminale yapıştır.",
        langNames: ({
            tur: "Türkçe", eng: "İngilizce", deu: "Almanca", fra: "Fransızca", spa: "İspanyolca",
            ita: "İtalyanca", por: "Portekizce", nld: "Felemenkçe", pol: "Lehçe", ukr: "Ukraynaca",
            rus: "Rusça", ara: "Arapça", jpn: "Japonca", kor: "Korece", chi_sim: "Çince (Basit)"
        })
    })

    readonly property var en: ({
        dragRegion: "Drag a region      Esc to cancel",
        reading: "READING",
        dragHint: "Drag over the text to select it",
        lowConf: function (n) { return "Low confidence (" + n + "%)  ·  you can still select"; },
        noText: "No text found",
        noLang: "Language pack missing",
        copy: "Copy",
        copied: "Copied",
        selectAll: "Select all",
        settings: "Settings",
        readingLangs: "READING LANGUAGES",
        installed: "installed",
        download: "Download",
        howInstall: function (name) { return "How should " + name + " be installed?"; },
        direct: "Download directly",
        directHint: "No password, saved in your home folder",
        viaPm: "Install with the package manager",
        asksPassword: "asks for a password",
        copyCommand: "Copy command",
        runTerminal: "Run in terminal",
        terminalOpen: "Terminal is open, the list refreshes when it closes",
        installInfo: function (pm, os) {
            return "Download offers two ways: a direct download without a password, or " + pm
                + (os ? " (" + os + ")" : "") + " which asks for one.";
        },
        pmFallback: "your package manager",
        behaviour: "BEHAVIOUR",
        closeAfterCopy: "Close after copy",
        autoCopy: "Copy everything after reading",
        joinLines: "Join the lines of a paragraph",
        highlight: "HIGHLIGHT COLOUR",
        interfaceLang: "INTERFACE LANGUAGE",
        auto: "Auto",
        missing: function (list) { return "Missing: " + list; },
        grabFailed: "Could not take the screenshot (grim).",
        readFailed: function (why) { return "Reading failed (" + why + ")."; },
        readTimeout: "Reading took too long and was cancelled.",
        terminalClosed: "Terminal closed, the language list was refreshed.",
        installFailed: "Installation failed.",
        commandCopied: "Command copied, paste it into a terminal.",
        langNames: ({
            tur: "Turkish", eng: "English", deu: "German", fra: "French", spa: "Spanish",
            ita: "Italian", por: "Portuguese", nld: "Dutch", pol: "Polish", ukr: "Ukrainian",
            rus: "Russian", ara: "Arabic", jpn: "Japanese", kor: "Korean", chi_sim: "Chinese (Simplified)"
        })
    })
}

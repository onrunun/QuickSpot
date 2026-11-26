# QuickSpot

**Hızlı, %100 yerel çalışan macOS başlatıcısı — anlık bulanık arama, Apple Vision OCR, isteğe bağlı cihaz içi EmbeddingGemma 2 semantik görsel/belge arama, pano geçmişi, klasör gezgini, hızlı eylemler ve canlı önizleme.**

[English](README.md) · [Türkçe](README.tr.md)

[![CI](https://github.com/onrunun/QuickSpot/actions/workflows/ci.yml/badge.svg)](https://github.com/onrunun/QuickSpot/actions/workflows/ci.yml)
[![macOS 14+ Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-000000?logo=apple)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Öne Çıkan Özellikler

- **Anlık Uygulama & Dosya Arama** — Bellek içi sıfır-polling uygulama indeksi, frecency öğrenme, kısaltma eşleştirme (`vsc` → Visual Studio Code) ve Türkçe/Avrupa karakter normalizasyonu (`ı/i`, `ş/s`, `ğ/g`, `ß/ss` vb.).
- **Cihaz İçi Görsel ve PDF OCR Araması** — Ekran görüntüleri, fotoğraflar ve taranmış PDF'lerin içindeki metinleri Apple Vision OCR + SQLite FTS5 ile tamamen cihazınızda indeksler; QR kod ve IBAN akıllı algılaması içerir. Pil, sıcaklık ve Düşük Güç Moduna duyarlı arka plan indeksleme sunar.
- **İsteğe Bağlı Yerel Semantik Arama ve Tekrar Fotoğraf Bulucu** — Kullanıcının yerelde sağladığı EmbeddingGemma 2 GGUF ağırlıklarıyla Apple Silicon Metal üzerinde çalışır (`GemmaEmbed`, Apache-2.0): görselleri ve belgeleri anlamıyla arama, görsel olarak benzerleri bulma ve neredeyse aynı fotoğrafları temizleme sunar.
- **Spotlight Çakışma Koruması ve İlk Kurulum** — İlk açılışta Spotlight kısayolunu otomatik kontrol ederek çakışmasız başlar (`⌥Space` ile Spotlight'la birlikte kullanım, `⌘Space` ile Spotlight yerine kullanım ve özel kısayol kaydedici; canlı çakışma algılama ile rehberli kurulum).
- **Aşamalı Spotlight Araması ve Yol Gezgini** — Son dosyalar önbelleği, aşamalı Spotlight dosya araması ve `~/` veya `/` ile klasör içi gezinti (`Tab` ile klasöre girme).
- **Yerleşik Hızlı Eylemler ve Sistem Ayarları** — Hesap makinesi (`1500 + 18%`, `20% of 450`), renk dönüştürücü (`#3B82F6`, `rgb(59,130,246)`), birim ve Unix zaman damgası çevirici (`120 km to mi`), Terminal çalıştırıcı (`> git status`), URL açıcı, 27 macOS Sistem Ayarı kısayolu ve yıkıcı komutlarda çift onaylı sistem komutları.
- **Gizlilik Odaklı Pano Geçmişi (`cb:` / `⇧⌘V`)** — Şifre yöneticilerini (Apple Passwords, 1Password, Bitwarden, KeePassXC, LastPass, Dashlane) ve gizli/geçici pano türlerini otomatik olarak dışlayan, yalnızca kullanıcıya okunabilir (`0600`) yerel pano geçmişi.
- **Eylem Paleti (`⌘K`)** — Herhangi bir sonuç için ikincil eylemler: *Şununla Aç*, *Benzerlerini Bul*, *Klasörü Terminal'de Aç*, *Finder'da Göster*, *Quick Look*, *Yolu Kopyala*, *OCR Metnini Kopyala* ve onaylı *Çöp Sepetine Taşı*.
- **Çift Bölmeli Canlı Önizleme** — Küçük resimler, kod/metin önizlemesi (`.env`, `.pem`, `.key` gibi hassas dosyalar otomatik gizlenir), QR/IBAN eylemleri, Finder'a sürükle-bırak ve Quick Look (`Space` / `⌘Y`).
- **Doğal macOS Performansı** — Saf Swift, AppKit, SwiftUI, Vision, PDFKit, Metal, Accelerate ve SQLite3 ile; yalnızca isteğe bağlı yerel semantik arama için tek bir açık kaynak SwiftPM paketi ([GemmaEmbed](https://github.com/maralski/gemma-embed-swift), Apache-2.0) kullanır.

---

## %100 Yerel ve Gizlilik Odaklı

- **Telemetri, analitik veya takipçi içermez.**
- **Bulut API'si veya dış sunucu kullanmaz.** Vision OCR, PDF çözümleme, SQLite FTS5 indeksleme, isteğe bağlı EmbeddingGemma 2 Metal çıkarımı ve hesaplamaların tamamı Mac'inizde çalışır.
- **Otomatik ağ isteği yapmaz.** Arka planda model indirmez veya sunucuya bağlanmaz. Ağ bağlantısı yalnızca siz açıkça bir URL veya arama seçip tıkladığınızda varsayılan tarayıcınızda açılır.
- **Hassas dosya koruması.** `.env`, `.env.*`, `.pem`, `.key` ve SSH özel anahtarları önizleme panelinde gösterilmez.
- **Yerel depolama.** Yerel indeksler ve isteğe bağlı pano geçmişi (`0600` izinli) yalnızca `~/Library/Application Support/QuickSpot/` konumunda tutulur.

---

## Desteklenen Diller

QuickSpot macOS sistem dilinizi otomatik algılar ve Ayarlar (`⌘,`) penceresinden anlık olarak değiştirilebilir:

English · Türkçe · Deutsch · Español · Français · 日本語 · 简体中文 · Português (Brasil)

---

## Kaynaktan Derleme

### Gereksinimler
- Apple Silicon Mac (`arm64`) ve macOS 14.0 (Sonoma) veya üzeri
- Xcode Command Line Tools veya Xcode 16+ (Swift 6.0)

### Derleme ve Kurulum

```bash
git clone https://github.com/onrunun/QuickSpot.git
cd QuickSpot
./build.sh
cp -R build.noindex/QuickSpot.app /Applications/
open /Applications/QuickSpot.app
```

### Testleri Çalıştırma

```bash
swift test
```

> **macOS Gatekeeper Notu (Hazır İndirmeler):** Apple Developer ID ile notarize edilmemiş ad-hoc imzalı sürümlerde macOS ilk açılışta Gatekeeper uyarısı gösterebilir. Yukarıdaki gibi doğrudan kaynaktan derleyebilir veya hazır `.dmg` paketini ilk kez **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** seçeneğiyle (ya da `xattr -dr com.apple.quarantine /Applications/QuickSpot.app` komutuyla) açabilirsiniz.

---

## Topluluk, Güvenlik ve Lisans

- [Değişiklik Günlüğü](CHANGELOG.md) · [Katkı ve Çeviri Rehberi](CONTRIBUTING.md) · [Güvenlik Politikası](SECURITY.md) · [Davranış Kuralları](CODE_OF_CONDUCT.md) · [Üçüncü Parti Bildirimleri](THIRD_PARTY_NOTICES.md)
- [MIT Lisansı](LICENSE) altında yayınlanmıştır.

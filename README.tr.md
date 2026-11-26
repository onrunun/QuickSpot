# QuickSpot

**Hızlı, %100 yerel çalışan macOS başlatıcısı — anlık bulanık arama, Apple Vision OCR ile görsel/PDF içi metin arama, klasör gezgini, hızlı eylemler ve canlı önizleme.**

[English](README.md) · [Türkçe](README.tr.md)

---

## Öne Çıkan Özellikler

- **Anlık Uygulama & Dosya Arama** — Bellek içi sıfır-polling uygulama indeksi, frecency öğrenme, kısaltma eşleştirme (`vsc` → Visual Studio Code) ve Türkçe/Avrupa karakter normalizasyonu (`ı/i`, `ş/s`, `ğ/g`, `ß/ss` vb.).
- **Cihaz İçi Görsel ve PDF OCR Araması** — Ekran görüntüleri, fotoğraflar ve taranmış PDF'lerin içindeki metinleri Apple Vision OCR + SQLite FTS5 ile tamamen cihazınızda indeksler. Pil, sıcaklık ve Düşük Güç Moduna duyarlı arka plan indeksleme sunar.
- **Aşamalı Spotlight Araması ve Yol Gezgini** — Son dosyalar önbelleği, aşamalı Spotlight dosya araması ve `~/` veya `/` ile klasör içi gezinti (`Tab` ile klasöre girme).
- **Yerleşik Hızlı Eylemler ve Sistem Ayarları** — Hesap makinesi (`1500 + 18%`, `20% of 450`), renk dönüştürücü (`#3B82F6`, `rgb(59,130,246)`), birim ve Unix zaman damgası çevirici (`120 km to mi`), Terminal çalıştırıcı (`> git status`), URL açıcı, 27 macOS Sistem Ayarı kısayolu ve yıkıcı komutlarda çift onaylı sistem komutları.
- **Gizlilik Odaklı Pano Geçmişi (`cb:` / `⇧⌘V`)** — Şifre yöneticilerini (Apple Passwords, 1Password, Bitwarden, KeePassXC, LastPass, Dashlane) ve gizli/geçici pano türlerini otomatik olarak dışlayan, yalnızca kullanıcıya okunabilir (`0600`) yerel pano geçmişi.
- **Eylem Paleti (`⌘K`)** — Herhangi bir sonuç için ikincil eylemler: *Şununla Aç*, *Klasörü Terminal'de Aç*, *Finder'da Göster*, *Quick Look*, *Yolu Kopyala*, *OCR Metnini Kopyala* ve onaylı *Çöp Sepetine Taşı*.
- **Çift Bölmeli Canlı Önizleme** — Küçük resimler, kod/metin önizlemesi (`.env`, `.pem`, `.key` gibi hassas dosyalar otomatik gizlenir), OCR metnini tek tıkla kopyalama, Finder'a sürükle-bırak ve Quick Look (`Space` / `⌘Y`).
- **Harici Bağımlılık Yok** — Saf Swift, AppKit, SwiftUI, Vision, PDFKit ve SQLite3 ile geliştirilmiştir.

---

## %100 Yerel ve Gizlilik Odaklı

- **Telemetri, analitik veya takipçi içermez.**
- **Bulut API'si veya dış sunucu kullanmaz.** Vision OCR, PDF çözümleme, SQLite FTS5 indeksleme ve hesaplamaların tamamı Mac'inizde çalışır.
- **Otomatik ağ isteği yapmaz.** Ağ bağlantısı yalnızca siz açıkça bir URL veya Google araması seçip `Enter`'a bastığınızda varsayılan tarayıcınızda açılır.
- **Hassas dosya koruması.** `.env`, `.env.*`, `.pem`, `.key` ve SSH özel anahtarları önizleme panelinde gösterilmez.
- **Yerel depolama.** OCR veritabanı yalnızca `~/Library/Application Support/QuickSpot/image-ocr.sqlite` konumunda tutulur.

---

## Desteklenen Diller

QuickSpot macOS sistem dilinizi otomatik algılar ve Ayarlar (`⌘,`) penceresinden anlık olarak değiştirilebilir:

English · Türkçe · Deutsch · Español · Français · 日本語 · 简体中文 · Português (Brasil)

---

## Kaynaktan Derleme

### Gereksinimler
- macOS 14.0 (Sonoma) veya üzeri
- Xcode Command Line Tools veya Xcode 16+ (Swift 6.0)

### Derleme ve Kurulum

```bash
git clone https://github.com/<kullanici-adin>/QuickSpot.git
cd QuickSpot
./build.sh
cp -R build.noindex/QuickSpot.app /Applications/
open /Applications/QuickSpot.app
```

### Testleri Çalıştırma

```bash
swift test
```

---

## Lisans

[MIT Lisansı](LICENSE) altında yayınlanmıştır.

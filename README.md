# İndir — iPhone için kişisel video indirici

InShot'un Android'deki video indiricisine benzer, basit ve reklamsız bir iPhone uygulaması.
Uygulamanın içinde bir tarayıcı var. Siteye giriyorsun, videoyu oynatıyorsun, sağ alttaki
**⬇︎** düğmesinde bulunan videolar görünüyor ve tek dokunuşla indiriliyor.

## Özellikler

- Yerleşik tarayıcı: adres çubuğu, Google araması, ileri/geri, kısayollar, açılır pencere engelleme
- Sayfadaki videoları otomatik yakalama (`<video>` etiketleri, og:video, ağ istekleri, iframe'ler)
- Doğrudan dosyalar (MP4, MOV, WEBM…) ve **HLS akışları (m3u8)**. Akışlar otomatik olarak MP4'e çevrilir
- Ekran kapalıyken de devam eden arka plan indirmesi
- İndirilenleri **Fotoğraflar'a otomatik kaydetme** (kapatılabilir)
- Uygulama içi oynatıcı, paylaşma, silme
- Dosyalar uygulamasında görünür: *Dosyalar → iPhone'umda → İndir*
- Panodaki bağlantıyı tek dokunuşla açma ("Yapıştır" düğmesi)

## iPhone'a kurulum (Windows PC ile)

Uygulama App Store'da olmadığı için **Sideloadly** ile kendi Apple ID'nle kuruyorsun.

1. **Hazırlık (bir kerelik):** PC'ye Apple'ın sitesinden **iTunes** ve **iCloud** kur.
   Microsoft Store sürümleri değil, apple.com'daki "Windows için" sürümler olmalı.
   Sonra [sideloadly.io](https://sideloadly.io) adresinden Sideloadly'yi indir.
2. **IPA dosyasını indir:** Bu deponun **Releases → latest** bölümünden `Indir.ipa` dosyasını indir.
3. iPhone'u kabloyla PC'ye bağla. Telefonda "Bu bilgisayara güven" sorusuna **Güven** de.
4. Sideloadly'yi aç. `Indir.ipa` dosyasını pencereye sürükle, Apple ID e-postanı yaz, **Start**'a bas.
   Apple ID şifresini Sideloadly ister. Şifre yalnızca Apple'a gider.
5. iPhone'da:
   - **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu**'nu aç. Telefon yeniden başlar.
   - **Ayarlar → Genel → VPN ve Aygıt Yönetimi**'nde kendi Apple ID'ne dokun ve **Güven** de.
6. "İndir" uygulamasını aç. İlk kaydetmede Fotoğraflar izni ister.

**7 gün kuralı:** Ücretsiz Apple ID ile kurulan uygulama 7 gün sonra açılmaz.
Sideloadly'de aynı işlemi tekrarlaman yeterli, indirdiğin dosyalar silinmez.
Sideloadly'nin *Auto-refresh* seçeneği PC açıkken ve aynı Wi‑Fi'deyken bunu kendisi yapar.
Yıllık 99$'lık Apple Developer hesabın olursa süre 1 yıla çıkar.

## Kullanım

1. **Tarayıcı** sekmesinde siteye gir veya bağlantıyı yapıştır.
2. Videoyu **oynat**. Birçok site video adresini ancak oynatınca yükler.
3. Sağ alttaki düğme renklenip sayı gösterince dokun. Listeden videoyu seçip ⬇︎'ye bas.
   Birden fazla seçenek varsa genelde boyutu en büyük olan en iyi kalitedir.
4. **İndirilenler** sekmesinden izle, paylaş, Fotoğraflar'a kaydet (sola kaydır) veya sil (sağa kaydır).

## Sınırlamalar

- **DRM korumalı** siteler (Netflix, Disney+, Spotify vb.) indirilemez. Bu teknik ve yasal bir sınır.
- Videoyu parça parça `blob:` olarak oynatan siteler (YouTube, Instagram, X gibi büyük platformlar)
  çoğunlukla yakalanamaz. Uygulama, video dosyasını veya m3u8 akışını açıkça yükleyen sitelerde en iyi sonucu verir.
- WEBM/MKV gibi biçimler Fotoğraflar'a kaydedilemez. Bunlar Dosyalar uygulamasında kalır.
- İndirdiğin içeriklerin telif haklarına ve sitelerin kullanım koşullarına uymak senin sorumluluğunda.

## Geliştirme

Kod `Indir/` klasöründe (SwiftUI, iOS 16+). Xcode projesi `project.yml` dosyasından
[XcodeGen](https://github.com/yonaskolb/XcodeGen) ile üretilir. Her push'ta GitHub Actions
macOS üzerinde imzasız `Indir.ipa` derler. Varsayılan dalda bu dosya **Releases → latest** olarak yayınlanır.

Mac'te yerel derleme:

```sh
brew install xcodegen
xcodegen generate
open Indir.xcodeproj
```

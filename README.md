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

## iPhone'a kurulum: SideStore (PC'ye sadece bir kez gerek var)

SideStore, uygulamayı kendi Apple ID'nle imzalayıp **7 günlük süreyi telefonun üzerinden yeniler**.
PC'ye yalnızca ilk kurulumda ihtiyaç var. Sonrasında kablo da PC de gerekmez.

### A. PC'de hazırlık (bir kerelik)
1. **iTunes**'u apple.com'dan kur. Microsoft Store sürümü değil, "Windows için iTunes" olmalı.
   iloader'ın telefonu görebilmesi için iTunes'un sürücüsü gerekiyor.
2. **iloader**'ı SideStore'un sitesinden ([docs.sidestore.io](https://docs.sidestore.io/docs/installation/install)) indir ve kur.

### B. iPhone'da hazırlık
1. App Store'dan **LocalDevVPN** uygulamasını kur. SideStore'un PC'siz yenileme yapabilmesi için gerekli.
2. **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu**'nu aç. Telefon yeniden başlar ve açılınca onay ister.

### C. SideStore'u kur
1. iPhone'u kabloyla PC'ye bağla. Telefonda **Güven** de ve şifreni gir.
2. iloader'ı aç, Apple ID'nle giriş yap, telefonunu seç ve **Install SideStore (Stable)**'a bas.
3. iPhone'da **Ayarlar → Genel → VPN ve Aygıt Yönetimi**'nde kendi Apple ID'ne dokun ve **Güven** de.
4. **LocalDevVPN**'i aç ve **Connect**'e bas.
5. **SideStore**'u aç ve aynı Apple ID ile giriş yap. *My Apps* sekmesinde SideStore'un yanındaki
   **7 DAYS** yazısına dokunup bir kez yenile. Yenileme başarılıysa kurulum tamam, kabloyu çıkarabilirsin.

### D. İndir'i SideStore'dan kur
1. SideStore'da **Sources → +** düğmesine bas ve şu adresi ekle:
   ```
   https://github.com/Deligom/Veri-aktar-m-/releases/download/latest/source.json
   ```
2. Kaynakta **İndir**'i bul ve **Free / Install**'a bas. LocalDevVPN açık olmalı.
3. Yeni bir sürüm çıktığında SideStore'da güncelleme olarak görünür. Dosya indirmene gerek kalmaz.

> İndir'i daha önce Sideloadly ile kurduysan önce telefondan sil. SideStore yalnızca kendi kurduğu uygulamaları yenileyebilir.
> İndirdiğin videolar Fotoğraflar'a kaydedildiyse silinmez.

### 7 günlük yenileme
- Birkaç günde bir **LocalDevVPN → Connect**, sonra **SideStore → My Apps → Refresh All**. Bu kadar, her yerde çalışır.
- SideStore'un arka planda kendiliğinden yenileme özelliği de var. iOS her zaman izin vermediği için
  süre bitmeden arada bir elle yenilemek en garantisi. Süre tamamen biterse uygulamalar açılmaz,
  ama SideStore'dan yenileyince geri gelir. Veriler silinmez.
- SideStore'un kendi süresi de dolarsa onu da aynı şekilde yenilersin. Nadiren ("pairing file" bozulursa)
  bir kez daha iloader ile PC'ye bağlamak gerekebilir.
- Ücretsiz Apple ID ile aynı anda en fazla **3 uygulama** kurulabilir. SideStore kendisi bunlardan biri sayılır.

### Alternatif: Sideloadly
Sadece PC ile kurmak istersen bu deponun **Releases → latest** bölümündeki `Indir.ipa` dosyasını
[Sideloadly](https://sideloadly.io) ile kurabilirsin. Bu yolda "Auto-refresh" seçeneği, PC açıkken ve
telefon aynı Wi‑Fi'deyken yenilemeyi kendisi yapar.

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

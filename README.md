<div align="center">

<img src=".github/assets/icon-musicless.png" width="112" height="112" alt="NewTube Musicless icon">

# NewTube Musicless

### YouTube on your phone, without the music.

A fork of [NewTube](https://github.com/aleixrodriala/newtube) (itself built on
[SmartTube](https://github.com/yuliskov/SmartTube)) that removes music from videos on the phone
and keeps the voices. Made for Muslims who avoid music, with an Arabic interface by default.

[![Latest release](https://img.shields.io/github/v/release/yshalsager/newtube-musicless?style=flat-square&label=release&color=0E6B52)](https://github.com/yshalsager/newtube-musicless/releases/latest)
[![Android 7.0+](https://img.shields.io/badge/Android-7.0%2B-0E6B52?style=flat-square)](#download)
[![License: MIT](https://img.shields.io/badge/license-MIT-0E6B52?style=flat-square)](LICENSE)

**[Download](#download) · [How it works](#how-it-works) · [العربية](#بالعربية) · [Credits](#credits)**

</div>

> [!NOTE]
> This is an independent fork. It is not made or endorsed by NewTube's or SmartTube's developers,
> and their apps are not responsible for it. Everything except music removal and the defaults below
> is NewTube's and SmartTube's work: see [NewTube's README](docs/UPSTREAM_README_NewTube.md).

## What it adds to NewTube

- **Remove music, on by default.** The phone separates each video's sound into voices and music
  with a small AI model and plays only the voices. Turn it on or off in Settings or in the
  player's menu (the gear icon), for videos and audio-only playback.
- **Defaults for a Muslim audience** on a fresh install: Arabic interface, no Home feed (YouTube's
  signed-out Home can't be filtered), no Up next suggestions, videos pause when they end, and
  thumbnails taken from the video itself instead of the uploader's (DeArrow). Shorts are always
  hidden, as in NewTube. Everything can be changed in Settings.
- **Full Arabic translation** of the phone screens.
- **Its own app**, with its own icon and updates from this repo. It installs next to official
  NewTube and doesn't replace it.

## Download

Get `NewTube_<version>_arm64-v8a.apk` from the
**[latest release](https://github.com/yshalsager/newtube-musicless/releases/latest)**. That fits
almost every phone from the last few years; take the `universal` APK if you're not sure. The app
checks this repo for updates by itself.

On first launch it downloads the voice model (about 35 MB) once. Every release is built and
signed by GitHub Actions from its tag, with a [build attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
for each APK:

```
gh attestation verify NewTube_<version>_arm64-v8a.apk -R yshalsager/newtube-musicless
```

Signing certificate SHA-256: `1490631944f31de3697ef4df013971d729adfa3c888c4a5360d57e4c5b29f741`

## How it works

The separation runs **on the phone**: no audio leaves it. NewTube decodes the video's sound as
usual; Musicless feeds it, in windows of up to 12 seconds, through the two halves of
[Spleeter](https://github.com/deezer/spleeter)'s 2-stem model (voices and accompaniment) with
[ONNX Runtime](https://onnxruntime.ai), keeps the voice part and plays that in sync with the
picture. The first window is short, so playback starts within a second or two; while the voices
aren't ready, the player waits and shows "Preparing voices…".

Limits worth knowing:

- It keeps **all** voices, singing included, so a song still has its singer.
- Percussion such as the daff is mostly removed with the rest of the music.
- It uses more battery and memory than plain playback, and the APK is about 35 MB larger than
  NewTube because of ONNX Runtime.
- It's tested on regular videos; live streams haven't been checked.

The developer-side details (code map, fork build, release process, keeping up with NewTube) are
in **[docs/musicless/HANDOFF.md](docs/musicless/HANDOFF.md)**.

## بالعربية

**NewTube Musicless** نسخة من تطبيق NewTube (المبني على SmartTube) تُزيل الموسيقى من فيديوهات
يوتيوب على هاتفك وتُبقي الأصوات، وموجّهة للمسلمين الذين يتجنبون الموسيقى.

- **إزالة الموسيقى مفعّلة افتراضيًا**: يفصل الهاتف صوت الفيديو إلى أصوات وموسيقى بنموذج ذكاء
  اصطناعي صغير، ويشغّل الأصوات فقط. التشغيل والإيقاف من الإعدادات أو من قائمة المشغّل.
- **المعالجة على هاتفك**: لا يُرسَل أي صوت إلى أي خادم.
- **إعدادات مناسبة**: واجهة عربية، بدون الصفحة الرئيسية ولا المقاطع القصيرة (Shorts)، بدون
  اقتراحات «التالي»، وصور مصغّرة من لقطات الفيديو نفسه.
- **تطبيق مستقل** بأيقونة خضراء، يُثبَّت بجانب NewTube الرسمي ويتحدّث تلقائيًا من هذا المستودع.

تنبيه: يُبقي التطبيق كل الأصوات البشرية بما فيها الغناء، ويُزيل معظم الإيقاع كالدف. عند أول
تشغيل يُنزَّل نموذج الأصوات (نحو 35 ميغابايت) مرة واحدة.

**التنزيل**: ملف `arm64-v8a` من [آخر إصدار](https://github.com/yshalsager/newtube-musicless/releases/latest).

## Credits

| Project | By | Used for |
|:--|:--|:--|
| [NewTube](https://github.com/aleixrodriala/newtube) | [@aleixrodriala](https://github.com/aleixrodriala) and contributors | The phone app this fork is built on |
| [SmartTube](https://github.com/yuliskov/SmartTube) | [@yuliskov](https://github.com/yuliskov) and contributors | The engine, accounts and integrations under NewTube |
| [Musicless](https://github.com/ieasybooks/musicless) | [الكتب المُيسّرة (ieasybooks)](https://github.com/ieasybooks) (MIT) | The idea and the separation method: the voice mask and DSP are ported from it |
| [Spleeter](https://github.com/deezer/spleeter) | Deezer (MIT) | The 2-stem separation model |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | k2-fsa | The ONNX export of the Spleeter model |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Microsoft (MIT) | Running the model on the phone |
| [SponsorBlock](https://sponsor.ajay.app) · [DeArrow](https://dearrow.ajay.app) | Ajay Ramachandran and contributors | Segment and thumbnail data (CC BY-NC-SA 4.0) |
| [Return YouTube Dislike](https://returnyoutubedislike.com) | RYD contributors | Dislike counts |
| [androidx Media3](https://developer.android.com/media/media3) | Google (Apache-2.0) | Playback |

Licenses for the Musicless parts ship inside the app (`assets/musicless/`); the rest are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). If you find this useful, consider
[supporting SmartTube](https://github.com/yuliskov/SmartTube#donation), whose work is underneath.

## License

[MIT](LICENSE), the same as NewTube and SmartTube. © yuliskov (SmartTube), NewTube contributors and
NewTube Musicless contributors.

---

*NewTube Musicless is an independent, unofficial project. It is not affiliated with, funded,
authorized or endorsed by Google LLC, YouTube, NewTube's or SmartTube's developers, Deezer,
Microsoft or ieasybooks, and it hosts no content. YouTube, Android and Google are trademarks of
Google LLC.*

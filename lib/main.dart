import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF12101F)),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

const demos = [
  ['@nour.cooks', 'أسرع فطار في 5 دقايق', 0xFFFF3D81, 0xFF7B2FF7],
  ['@karim_fit', 'تمرين الصبح من غير أجهزة', 0xFF2EE6D6, 0xFF1B4FD8],
  ['@mona.travel', 'أحلى أماكن في الغردقة', 0xFFFFB347, 0xFF4B1D9E],
  ['@dev.ahmed', 'نصيحة سريعة في البرمجة', 0xFF3A0CA3, 0xFFF72585],
];

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0, page = 0;
  List<AssetEntity> local = [];
  bool loaded = false, denied = false;

  Future<void> loadLocal() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => denied = true);
      return;
    }
    final paths = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: true);
    final list = paths.isEmpty ? <AssetEntity>[] : await paths.first.getAssetListRange(start: 0, end: 200);
    setState(() {
      local = list;
      loaded = true;
      denied = false;
    });
  }

  void setTab(int t) {
    setState(() {
      tab = t;
      page = 0;
    });
    if (t == 1 && !loaded) loadLocal();
  }

  Widget body() {
    if (tab == 0) {
      return PageView.builder(
        key: const ValueKey('online'),
        scrollDirection: Axis.vertical,
        itemCount: demos.length,
        itemBuilder: (c, i) => Stack(fit: StackFit.expand, children: [
          Container(
            decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(demos[i][2] as int), Color(demos[i][3] as int)], begin: Alignment.topRight, end: Alignment.bottomLeft)),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(40),
            child: Text(demos[i][1] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
          ),
          Actions(user: demos[i][0] as String, desc: demos[i][1] as String, badge: 'أونلاين (تجريبي)'),
        ]),
      );
    }
    if (denied) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('محتاج إذن الوصول لفيديوهات الهاتف', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 16),
        FilledButton(onPressed: PhotoManager.openSetting, child: const Text('فتح الإعدادات')),
      ]));
    }
    if (!loaded) return const Center(child: CircularProgressIndicator());
    if (local.isEmpty) return const Center(child: Text('مفيش فيديوهات في هاتفك'));
    return PageView.builder(
      key: const ValueKey('local'),
      scrollDirection: Axis.vertical,
      itemCount: local.length,
      onPageChanged: (i) => setState(() => page = i),
      itemBuilder: (c, i) => LocalVideo(asset: local[i], active: i == page),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          Positioned.fill(child: body()),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final e in [[0, 'لك'], [1, 'جهازي']])
                  TextButton(
                    onPressed: () => setTab(e[0] as int),
                    child: Text(e[1] as String,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: tab == e[0] ? Colors.white : Colors.white54)),
                  ),
              ]),
            ),
          ),
        ]),
      );
}

class LocalVideo extends StatefulWidget {
  final AssetEntity asset;
  final bool active;
  const LocalVideo({super.key, required this.asset, required this.active});
  @override
  State<LocalVideo> createState() => _LocalVideoState();
}

class _LocalVideoState extends State<LocalVideo> {
  VideoPlayerController? c;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final f = await widget.asset.file;
    if (f == null || !mounted) return;
    final ctrl = VideoPlayerController.file(f);
    await ctrl.initialize();
    ctrl.setLooping(true);
    if (!mounted) {
      ctrl.dispose();
      return;
    }
    setState(() => c = ctrl);
    if (widget.active) ctrl.play();
  }

  @override
  void didUpdateWidget(LocalVideo old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      if (widget.active) {
        c?.play();
      } else {
        c?.pause();
        c?.seekTo(Duration.zero);
      }
    }
  }

  @override
  void dispose() {
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = c;
    return Stack(fit: StackFit.expand, children: [
      Container(color: Colors.black),
      if (v != null && v.value.isInitialized)
        GestureDetector(
          onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
          child: Center(child: AspectRatio(aspectRatio: v.value.aspectRatio, child: V

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF12101F),
      ),
      builder: (c, w) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: w!,
        );
      },
      home: const Home(),
    );
  }
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
  int tab = 0;
  int page = 0;
  List<AssetEntity> local = [];
  bool loaded = false;
  bool denied = false;

  Future<void> loadLocal() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => denied = true);
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );
    List<AssetEntity> list = [];
    if (paths.isNotEmpty) {
      list = await paths.first.getAssetListRange(start: 0, end: 200);
    }
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

  Widget demoPage(int i) {
    final d = demos[i];
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(d[2] as int), Color(d[3] as int)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(40),
          child: Text(
            d[1] as String,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        ReelActions(
          user: d[0] as String,
          desc: d[1] as String,
          badge: 'أونلاين (تجريبي)',
        ),
      ],
    );
  }

  Widget body() {
    if (tab == 0) {
      return PageView.builder(
        key: const ValueKey('online'),
        scrollDirection: Axis.vertical,
        itemCount: demos.length,
        itemBuilder: (c, i) => demoPage(i),
      );
    }
    if (denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'محتاج إذن الوصول لفيديوهات الهاتف',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => PhotoManager.openSetting(),
              child: const Text('فتح الإعدادات'),
            ),
          ],
        ),
      );
    }
    if (!loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (local.isEmpty) {
      return const Center(child: Text('مفيش فيديوهات في هاتفك'));
    }
    return PageView.builder(
      key: const ValueKey('local'),
      scrollDirection: Axis.vertical,
      itemCount: local.length,
      onPageChanged: (i) => setState(() => page = i),
      itemBuilder: (c, i) {
        return LocalVideo(asset: local[i], active: i == page);
      },
    );
  }

  Widget tabButton(int index, String label) {
    final on = tab == index;
    return TextButton(
      onPressed: () => setTab(index),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: on ? Colors.white : Colors.white54,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: body()),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  tabButton(0, 'لك'),
                  tabButton(1, 'جهازي'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LocalVideo extends StatefulWidget {
  final AssetEntity asset;
  final bool active;

  const LocalVideo({
    super.key,
    required this.asset,
    required this.active,
  });

  @override
  State<LocalVideo> createState() => _LocalVideoState();
}

class _LocalVideoState extends State<LocalVideo> {
  VideoPlayerController? ctrl;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final f = await widget.asset.file;
    if (f == null || !mounted) return;
    final vc = VideoPlayerController.file(f);
    await vc.initialize();
    vc.setLooping(true);
    if (!mounted) {
      vc.dispose();
      return;
    }
    setState(() => ctrl = vc);
    if (widget.active) vc.play();
  }

  @override
  void didUpdateWidget(LocalVideo old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      ctrl?.play();
    } else {
      ctrl?.pause();
      ctrl?.seekTo(Duration.zero);
    }
  }

  @override
  void dispose() {
    ctrl?.dispose();
    super.dispose();
  }

  void togglePlay() {
    final v = ctrl;
    if (v == null) return;
    setState(() {
      if (v.value.isPlaying) {
        v.pause();
      } else {
        v.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = ctrl;
    final ready = v != null && v.value.isInitialized;
    Widget content;
    if (ready) {
      content = GestureDetector(
        onTap: togglePlay,
        child: Center(
          child: AspectRatio(
            aspectRatio: v.value.aspectRatio,
            child: VideoPlayer(v),
          ),
        ),
      );
    } else {
      content = const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        content,
        ReelActions(
          user: '@أنا',
          desc: widget.asset.title ?? 'فيديو من هاتفك',
          badge: 'من هاتفك',
        ),
      ],
    );
  }
}

class ReelActions extends StatefulWidget {
  final String user;
  final String desc;
  final String badge;

  const ReelActions({
    super.key,
    required this.user,
    required this.desc,
    required this.badge,
  });

  @override
  State<ReelActions> createState() => _ReelActionsState();
}

class _ReelActionsState extends State<ReelActions> {
  bool liked = false;
  bool saved = false;
  int likes = 0;
  final List<String> comments = [];

  void openComments() {
    final ctl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, set) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SizedBox(
                height: 320,
                child: Column(
                  children: [
                    Expanded(child: commentList()),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: ctl,
                            decoration: const InputDecoration(
                              hintText: 'اكتب تعليق',
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: () {
                            final t = ctl.text.trim();
                            if (t.isEmpty) return;
                            comments.add(t);
                            ctl.clear();
                            set(() {});
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget commentList() {
    if (comments.isEmpty) {
      return const Center(child: Text('ابدأ أول تعليق'));
    }
    return ListView(
      children: [
        for (final t in comments) ListTile(title: Text(t)),
      ],
    );
  }

  Widget btn(IconData icon, String label, VoidCallback f, Color? color) {
    return Column(
      children: [
        IconButton(
          iconSize: 32,
          icon: Icon(icon, color: color),
          onPressed: f,
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          bottom: 30,
          right: 16,
          left: 90,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.user,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.desc,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Chip(
                backgroundColor: const Color(0xFF2EE6D6),
                label: Text(
                  widget.badge,
                  style: const TextStyle(
                    color: Color(0xFF06211F),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          bottom: 30,
          left: 8,
          child: Column(
            children: [
              btn(
                Icons.favorite,
                '$likes',
                () => setState(() {
                  liked = !liked;
                  likes += liked ? 1 : -1;
                }),
                liked ? const Color(0xFFFF3D81) : null,
              ),
              btn(
                Icons.chat_bubble,
                '${comments.length}',
                openComments,
                null,
              ),
              btn(
                Icons.star,
                'حفظ',
                () => setState(() => saved = !saved),
                saved ? const Color(0xFFFFC857) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

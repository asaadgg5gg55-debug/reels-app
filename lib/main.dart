import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const App());

const List<Map<String, String>> defaultLinks = [
  {'name': 'xfree', 'url': 'https://www.xfree.com'},
];

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Colors.black,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
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

void toast(BuildContext ctx, String msg) {
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(content: Text(msg)),
  );
}

const ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<void> downloadVideo(
  BuildContext ctx,
  String url,
  String? ref,
) async {
  if (url.startsWith('blob:') || url.contains('.m3u8')) {
    toast(ctx, 'الموقع ده بيحمي الفيديو، مش هقدر أحمّله');
    return;
  }
  toast(ctx, 'جاري التحميل...');
  try {
    await PhotoManager.requestPermissionExtend();
    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] = ua;
    if (ref != null && ref.isNotEmpty) {
      req.headers['Referer'] = ref;
    }
    final resp = await http.Client().send(req);
    final type = resp.headers['content-type'] ?? '';
    if (resp.statusCode != 200 || type.contains('text')) {
      throw Exception('bad response');
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dir = Directory.systemTemp.path;
    final f = File('$dir/v$stamp.mp4');
    await resp.stream.pipe(f.openWrite());
    await PhotoManager.editor.saveVideo(
      f,
      title: 'video_$stamp.mp4',
    );
    await f.delete();
    toast(ctx, 'تم الحفظ في معرض الهاتف');
  } catch (e) {
    toast(ctx, 'فشل التحميل');
  }
}

Future<void> askAndDownload(BuildContext ctx) async {
  final t = TextEditingController();
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (d) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('تحميل من رابط مباشر'),
        content: TextField(
          controller: t,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'الصق رابط الفيديو',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('تحميل'),
          ),
        ],
      );
    },
  );
  final u = t.text.trim();
  if (ok != true || u.isEmpty || !ctx.mounted) return;
  await downloadVideo(ctx, u, null);
}

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
      list = await paths.first.getAssetListRange(
        start: 0,
        end: 200,
      );
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

  Widget deviceBody() {
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

  Widget body() {
    if (tab == 0) {
      return const Padding(
        padding: EdgeInsets.only(top: 90),
        child: LinksTab(),
      );
    }
    return deviceBody();
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
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: body()),
          SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tabButton(0, 'روابطي'),
                      tabButton(1, 'جهازي'),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.download),
                    onPressed: () => askAndDownload(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LinksTab extends StatefulWidget {
  const LinksTab({super.key});

  @override
  State<LinksTab> createState() => _LinksTabState();
}

class _LinksTabState extends State<LinksTab> {
  List<Map<String, String>> extra = [];

  List<Map<String, String>> get all {
    return [...defaultLinks, ...extra];
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('links');
    if (raw == null) return;
    final list = jsonDecode(raw) as List;
    setState(() {
      extra = list
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    });
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('links', jsonEncode(extra));
  }

  Future<void> addLink() async {
    final n = TextEditingController();
    final u = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('إضافة رابط'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(
                  hintText: 'الاسم',
                ),
              ),
              TextField(
                controller: u,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'الرابط',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
    var url = u.text.trim();
    if (ok != true || url.isEmpty) return;
    if (!url.startsWith('http')) url = 'https://$url';
    var name = n.text.trim();
    if (name.isEmpty) name = url;
    setState(() => extra.add({'name': name, 'url': url}));
    await save();
  }

  void open(Map<String, String> l) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) {
          return WebPage(title: l['name']!, url: l['url']!);
        },
      ),
    );
  }

  Widget linkTile(int i) {
    final l = all[i];
    final deletable = i >= defaultLinks.length;
    Widget? trailing;
    if (deletable) {
      trailing = IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          setState(() => extra.removeAt(i - defaultLinks.length));
          await save();
        },
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        leading: const Icon(Icons.play_circle_outline),
        title: Text(l['name']!),
        subtitle: Text(
          l['url']!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.right,
          style: const TextStyle(color: Colors.white54),
        ),
        trailing: trailing,
        onTap: () => open(l),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = all;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (c, i) => linkTile(i),
          ),
        ),
        Positioned(
          bottom: 24,
          left: 24,
          child: FloatingActionButton(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            onPressed: addLink,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class WebPage extends StatefulWidget {
  final String title;
  final String url;

  const WebPage({super.key, required this.title, required this.url});

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  late final WebViewController c;
  String current = '';

  static const findJs = r'''
(function(){
  var vs=document.querySelectorAll("video");
  var best=null;
  var bestScore=0;
  var h=window.innerHeight;
  var w=window.innerWidth;
  for(var i=0;i<vs.length;i++){
    var v=vs[i];
    var r=v.getBoundingClientRect();
    var vw=Math.min(r.right,w)-Math.max(r.left,0);
    var vh=Math.min(r.bottom,h)-Math.max(r.top,0);
    if(vw<=0||vh<=0)continue;
    var score=vw*vh;
    if(!v.paused)score=score*2;
    if(score>bestScore){bestScore=score;best=v;}
  }
  if(!best)return "";
  var s=best.currentSrc||best.src||"";
  if(!s){
    var e=best.querySelector("source");
    if(e)s=e.src||"";
  }
  return s;
})()
''';

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(onPageStarted: (u) => current = u),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> grab() async {
    final r = await c.runJavaScriptReturningResult(findJs);
    if (!mounted) return;
    final u = r
        .toString()
        .replaceAll('"', '')
        .replaceAll(r'\/', '/')
        .trim();
    if (u.isEmpty || u == 'null') {
      toast(context, 'مفيش فيديو ظاهر في الصفحة');
      return;
    }
    await downloadVideo(context, u, current);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await c.canGoBack()) {
          c.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(
            widget.title,
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: () => askAndDownload(context),
            ),
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: grab,
            ),
          ],
        ),
        body: WebViewWidget(controller: c),
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
        ),
      ],
    );
  }
}

class ReelActions extends StatefulWidget {
  final String user;
  final String desc;

  const ReelActions({
    super.key,
    required this.user,
    required this.desc,
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
      backgroundColor: const Color(0xFF1A1A1A),
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

  Widget btn(IconData icon, String label, VoidCallback f, bool on) {
    return Column(
      children: [
        IconButton(
          iconSize: 32,
          icon: Icon(
            icon,
            color: on ? Colors.white : Colors.white60,
          ),
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
            ],
          ),
        ),
        Positioned(
          bottom: 30,
          left: 8,
          child: Column(
            children: [
              btn(
                liked ? Icons.favorite : Icons.favorite_border,
                '$likes',
                () => setState(() {
                  liked = !liked;
                  likes += liked ? 1 : -1;
                }),
                liked,
              ),
              btn(
                Icons.chat_bubble_outline,
                '${comments.length}',
                openComments,
                false,
              ),
              btn(
                saved ? Icons.bookmark : Icons.bookmark_border,
                'حفظ',
                () => setState(() => saved = !saved),
                saved,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

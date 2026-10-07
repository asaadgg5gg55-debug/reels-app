import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'main.dart';

// ---------------------------------------------------------------
// إعدادات Cloudinary (تُحفظ في الهاتف، تكتبها مرة واحدة من التطبيق)
// ---------------------------------------------------------------

class CloudConfig {
  final String cloud;
  final String preset;

  const CloudConfig(this.cloud, this.preset);

  bool get ok => cloud.isNotEmpty && preset.isNotEmpty;

  static Future<CloudConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return CloudConfig(
      p.getString('cloud_name') ?? '',
      p.getString('cloud_preset') ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cloud_name', cloud);
    await p.setString('cloud_preset', preset);
  }
}

Future<CloudConfig?> showCloudSettings(
  BuildContext ctx,
  CloudConfig current,
) async {
  final a = TextEditingController(text: current.cloud);
  final b = TextEditingController(text: current.preset);
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (d) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('إعدادات التخزين'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'انسخهم من حسابك في cloudinary.com',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            TextField(
              controller: a,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(hintText: 'Cloud name'),
            ),
            TextField(
              controller: b,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                hintText: 'Upload preset (Unsigned)',
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
  if (ok != true) return null;
  final cfg = CloudConfig(a.text.trim(), b.text.trim());
  await cfg.save();
  return cfg;
}

// ---------------------------------------------------------------
// المنشورات
// ---------------------------------------------------------------

const cloudTag = 'reelsapp';

class Post {
  final String id;
  final String url;
  final String caption;
  final int time;

  const Post({
    required this.id,
    required this.url,
    required this.caption,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'caption': caption,
        'time': time,
      };

  factory Post.fromJson(Map m) => Post(
        id: m['id'].toString(),
        url: m['url'].toString(),
        caption: (m['caption'] ?? '').toString(),
        time: (m['time'] as num?)?.toInt() ?? 0,
      );
}

class PostStore {
  static Future<List<Post>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('posts');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Post.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Post> l) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'posts',
      jsonEncode(l.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> add(Post post) async {
    final l = await load();
    l.removeWhere((e) => e.id == post.id);
    l.insert(0, post);
    await _save(l);
  }

  static Future<Set<String>> hiddenIds() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList('hidden_posts') ?? []).toSet();
  }

  // إزالة من القائمة فقط (الملف يبقى في Cloudinary)
  static Future<void> hide(String id) async {
    final p = await SharedPreferences.getInstance();
    final h = await hiddenIds();
    h.add(id);
    await p.setStringList('hidden_posts', h.toList());
    final l = await load();
    l.removeWhere((e) => e.id == id);
    await _save(l);
  }

  // يجلب قائمة الفيديوهات من Cloudinary (حسب الوسم) ويدمجها مع المحلية.
  // يرجع null إذا فشل (مثلاً الخيار محظور في إعدادات الحساب).
  static Future<List<Post>?> syncRemote(List<Post> local) async {
    final cfg = await CloudConfig.load();
    if (!cfg.ok) return null;
    try {
      final uri = Uri.parse(
        'https://res.cloudinary.com/${cfg.cloud}/video/list/$cloudTag.json',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map;
      final hidden = await hiddenIds();
      final byId = {for (final p in local) p.id: p};
      for (final item in (j['resources'] as List? ?? [])) {
        final m = item as Map;
        final id = m['public_id'].toString();
        if (hidden.contains(id) || byId.containsKey(id)) continue;
        final fmt = (m['format'] ?? 'mp4').toString();
        final url = 'https://res.cloudinary.com/${cfg.cloud}'
            '/video/upload/v${m['version']}/$id.$fmt';
        final ctx = m['context'];
        String cap = '';
        if (ctx is Map && ctx['custom'] is Map) {
          cap = (ctx['custom']['caption'] ?? '').toString();
        }
        final t = DateTime.tryParse(
              (m['created_at'] ?? '').toString(),
            )?.millisecondsSinceEpoch ??
            0;
        byId[id] = Post(id: id, url: url, caption: cap, time: t);
      }
      final all = byId.values.toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      return all;
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------
// الرفع مع شريط تقدم
// ---------------------------------------------------------------

class _ProgressRequest extends http.MultipartRequest {
  final void Function(int sent, int total) onProgress;

  _ProgressRequest(String method, Uri url, this.onProgress)
      : super(method, url);

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    final stream = super.finalize();
    return http.ByteStream(
      stream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            sent += data.length;
            onProgress(sent, total);
            sink.add(data);
          },
        ),
      ),
    );
  }
}

String _escCtx(String s) {
  return s
      .replaceAll(r'\', r'\\')
      .replaceAll('=', r'\=')
      .replaceAll('|', r'\|');
}

Future<Post> uploadVideo(
  File file,
  String caption,
  CloudConfig cfg,
  void Function(double) onProgress,
) async {
  final uri = Uri.parse(
    'https://api.cloudinary.com/v1_1/${cfg.cloud}/video/upload',
  );
  final req = _ProgressRequest('POST', uri, (s, t) {
    onProgress(t == 0 ? 0 : s / t);
  });
  req.fields['upload_preset'] = cfg.preset;
  req.fields['tags'] = cloudTag;
  if (caption.isNotEmpty) {
    req.fields['context'] = 'caption=${_escCtx(caption)}';
  }
  req.files.add(await http.MultipartFile.fromPath('file', file.path));
  final resp = await req.send();
  final body = await resp.stream.bytesToString();
  Map j;
  try {
    j = jsonDecode(body) as Map;
  } catch (_) {
    throw Exception('رد غير مفهوم من الخادم (${resp.statusCode})');
  }
  if (resp.statusCode != 200) {
    final err = j['error'];
    final msg = err is Map ? err['message'] : null;
    throw Exception(msg?.toString() ?? 'فشل الرفع (${resp.statusCode})');
  }
  return Post(
    id: j['public_id'].toString(),
    url: j['secure_url'].toString(),
    caption: caption,
    time: DateTime.now().millisecondsSinceEpoch,
  );
}

// ---------------------------------------------------------------
// صفحة النشر
// ---------------------------------------------------------------

class PublishPage extends StatefulWidget {
  final File? initialFile;

  const PublishPage({super.key, this.initialFile});

  @override
  State<PublishPage> createState() => _PublishPageState();
}

class _PublishPageState extends State<PublishPage> {
  File? file;
  VideoPlayerController? pv;
  final caption = TextEditingController();
  CloudConfig cfg = const CloudConfig('', '');
  double? progress;
  bool uploading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    CloudConfig.load().then((c) {
      if (mounted) setState(() => cfg = c);
    });
    final f = widget.initialFile;
    if (f != null) {
      file = f;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setFile(f);
      });
    }
  }

  @override
  void dispose() {
    pv?.dispose();
    caption.dispose();
    super.dispose();
  }

  Future<void> setFile(File f) async {
    final old = pv;
    final vc = VideoPlayerController.file(f);
    setState(() {
      file = f;
      pv = null;
      error = null;
    });
    old?.dispose();
    try {
      await vc.initialize();
      vc.setLooping(true);
      vc.setVolume(0);
      vc.play();
    } catch (_) {
      // المعاينة اختيارية، الرفع يعمل حتى لو فشلت
    }
    if (!mounted) {
      vc.dispose();
      return;
    }
    setState(() => pv = vc);
  }

  Future<void> pick() async {
    final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    await setFile(File(x.path));
  }

  Future<void> settings() async {
    final c = await showCloudSettings(context, cfg);
    if (c != null && mounted) setState(() => cfg = c);
  }

  Future<void> publish() async {
    final f = file;
    if (f == null) {
      toast(context, 'اختار فيديو الأول');
      return;
    }
    if (!cfg.ok) {
      await settings();
      if (!cfg.ok) return;
    }
    setState(() {
      uploading = true;
      progress = 0;
      error = null;
    });
    try {
      final post = await uploadVideo(
        f,
        caption.text.trim(),
        cfg,
        (p) {
          if (mounted) setState(() => progress = p);
        },
      );
      await PostStore.add(post);
      if (!mounted) return;
      toast(context, 'تم النشر');
      Navigator.pop(context, post);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        uploading = false;
        progress = null;
        error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String sizeText() {
    final f = file;
    if (f == null) return '';
    final mb = f.lengthSync() / (1024 * 1024);
    return 'الحجم: ${mb.toStringAsFixed(1)} MB';
  }

  Widget preview() {
    final v = pv;
    Widget inner;
    if (file == null) {
      inner = const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library_outlined, size: 56),
          SizedBox(height: 12),
          Text('اضغط لاختيار فيديو من هاتفك'),
        ],
      );
    } else if (v != null && v.value.isInitialized) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: v.value.size.width,
            height: v.value.size.height,
            child: VideoPlayer(v),
          ),
        ),
      );
    } else {
      inner = const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      onTap: uploading ? null : pick,
      child: Container(
        height: 340,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(child: inner),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('نشر فيديو'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: uploading ? null : settings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          preview(),
          const SizedBox(height: 6),
          Text(
            sizeText(),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: caption,
            enabled: !uploading,
            maxLines: 3,
            maxLength: 150,
            decoration: const InputDecoration(
              hintText: 'اكتب وصف للفيديو...',
              border: OutlineInputBorder(),
            ),
          ),
          if (!cfg.ok)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1F00),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('لازم تضبط حساب التخزين (Cloudinary) مرة واحدة'),
                  ),
                  TextButton(
                    onPressed: settings,
                    child: const Text('إعداد'),
                  ),
                ],
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'فشل الرفع: $error',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          if (uploading) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(
              'جاري الرفع ${((progress ?? 0) * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: uploading ? null : publish,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(uploading ? 'جاري النشر...' : 'نشر'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------
// تبويب "منشوراتي"
// ---------------------------------------------------------------

class PostsTab extends StatefulWidget {
  const PostsTab({super.key});

  @override
  State<PostsTab> createState() => _PostsTabState();
}

class _PostsTabState extends State<PostsTab> {
  List<Post> posts = [];
  bool loading = true;
  int page = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final local = await PostStore.load();
    if (!mounted) return;
    setState(() {
      posts = local;
      loading = false;
    });
    final merged = await PostStore.syncRemote(local);
    if (!mounted || merged == null) return;
    if (merged.length != posts.length) setState(() => posts = merged);
  }

  Future<void> remove(Post p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('إزالة من منشوراتي؟'),
          content: const Text(
            'هيتشال من القائمة بس، والملف هيفضل على Cloudinary.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('إزالة'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    await PostStore.hide(p.id);
    if (!mounted) return;
    setState(() {
      posts.removeWhere((e) => e.id == p.id);
      if (page >= posts.length) page = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (posts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 56, color: Colors.white54),
            SizedBox(height: 12),
            Text('لسه ما نشرتش أي فيديو'),
            SizedBox(height: 6),
            Text(
              'اضغط على + فوق عشان تنشر أول فيديو',
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }
    return PageView.builder(
      key: const ValueKey('posts'),
      scrollDirection: Axis.vertical,
      itemCount: posts.length,
      onPageChanged: (i) => setState(() => page = i),
      itemBuilder: (c, i) {
        final p = posts[i];
        return CloudVideo(
          key: ValueKey(p.id),
          post: p,
          active: i == page,
          onRemove: () => remove(p),
        );
      },
    );
  }
}

class CloudVideo extends StatefulWidget {
  final Post post;
  final bool active;
  final VoidCallback onRemove;

  const CloudVideo({
    super.key,
    required this.post,
    required this.active,
    required this.onRemove,
  });

  @override
  State<CloudVideo> createState() => _CloudVideoState();
}

class _CloudVideoState extends State<CloudVideo> {
  VideoPlayerController? ctrl;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    if (failed) setState(() => failed = false);
    final vc = VideoPlayerController.networkUrl(Uri.parse(widget.post.url));
    try {
      await vc.initialize();
    } catch (_) {
      vc.dispose();
      if (mounted) setState(() => failed = true);
      return;
    }
    vc.setLooping(true);
    if (!mounted) {
      vc.dispose();
      return;
    }
    setState(() => ctrl = vc);
    if (widget.active) vc.play();
  }

  @override
  void didUpdateWidget(CloudVideo old) {
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
    Widget content;
    if (failed) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('تعذر تشغيل الفيديو'),
            const SizedBox(height: 8),
            FilledButton(onPressed: init, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    } else if (v != null && v.value.isInitialized) {
      content = GestureDetector(
        onTap: togglePlay,
        onLongPress: widget.onRemove,
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
        if (v != null && v.value.isInitialized)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              v,
              allowScrubbing: true,
              padding: EdgeInsets.zero,
            ),
          ),
        ReelActions(
          user: '@أنا',
          desc: widget.post.caption.isEmpty
              ? 'فيديو منشور'
              : widget.post.caption,
          extra: [
            ExtraAction(Icons.link, 'نسخ الرابط', () async {
              await Clipboard.setData(ClipboardData(text: widget.post.url));
              if (context.mounted) toast(context, 'تم نسخ الرابط');
            }),
          ],
        ),
      ],
    );
  }
}

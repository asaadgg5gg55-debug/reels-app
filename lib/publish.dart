import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'main.dart';

// ---------------------------------------------------------------
// تسجيل الدخول بحساب جوجل (Google Drive الخاص بك)
// صلاحية drive.file: التطبيق يرى فقط الملفات اللي رفعها هو
// ---------------------------------------------------------------

const driveScope = 'https://www.googleapis.com/auth/drive.file';
const driveFolderName = 'Reels';
const driveTag = 'reelsapp';

class DriveAuth {
  static final GoogleSignIn _g = GoogleSignIn(scopes: [driveScope]);

  static GoogleSignInAccount? get user => _g.currentUser;

  static Future<GoogleSignInAccount?> ensure({bool interactive = false}) async {
    GoogleSignInAccount? a = _g.currentUser;
    a ??= await _g.signInSilently();
    if (a == null && interactive) a = await _g.signIn();
    return a;
  }

  static Future<Map<String, String>?> headers({
    bool interactive = false,
    bool refresh = false,
  }) async {
    final a = await ensure(interactive: interactive);
    if (a == null) return null;
    if (refresh) await a.clearAuthCache();
    return a.authHeaders;
  }

  static Future<void> signOut() async {
    await _g.signOut();
    final p = await SharedPreferences.getInstance();
    await p.remove('drive_folder');
  }
}

String friendlyError(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  if (s.contains('ApiException: 10') || s.contains('DEVELOPER_ERROR')) {
    return 'إعداد تسجيل الدخول غير صحيح (تأكد من SHA-1 واسم الحزمة في Google Cloud)';
  }
  if (s.contains('sign_in_canceled') || s.contains('ApiException: 12501')) {
    return 'تم إلغاء تسجيل الدخول';
  }
  if (s.contains('network_error') || s.contains('SocketException')) {
    return 'مشكلة في الإنترنت';
  }
  return s;
}

Future<void> showDriveAccount(BuildContext ctx) async {
  await showDialog<void>(
    context: ctx,
    builder: (d) {
      return StatefulBuilder(
        builder: (d, set) {
          final u = DriveAuth.user;
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('حساب Google Drive'),
            content: Text(
              u == null ? 'غير مسجل الدخول' : u.email,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.right,
            ),
            actions: [
              if (u != null)
                TextButton(
                  onPressed: () async {
                    await DriveAuth.signOut();
                    set(() {});
                  },
                  child: const Text('تسجيل الخروج'),
                ),
              TextButton(
                onPressed: () async {
                  try {
                    if (u != null) await DriveAuth.signOut();
                    await DriveAuth.ensure(interactive: true);
                  } catch (e) {
                    if (d.mounted) toast(d, friendlyError(e));
                  }
                  set(() {});
                },
                child: Text(u == null ? 'تسجيل الدخول' : 'تبديل الحساب'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(d),
                child: const Text('إغلاق'),
              ),
            ],
          );
        },
      );
    },
  );
}

// ---------------------------------------------------------------
// المنشورات
// ---------------------------------------------------------------

String driveMediaUrl(String id) =>
    'https://www.googleapis.com/drive/v3/files/$id?alt=media';

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

  // إزالة من القائمة فقط (الملف يبقى في Drive)
  static Future<void> hide(String id) async {
    final p = await SharedPreferences.getInstance();
    final h = await hiddenIds();
    h.add(id);
    await p.setStringList('hidden_posts', h.toList());
    final l = await load();
    l.removeWhere((e) => e.id == id);
    await _save(l);
  }

  // يجلب قائمة الفيديوهات من Drive (اللي رفعها التطبيق) ويدمجها مع المحلية.
  // يرجع null إذا فشل (مثلاً مش مسجل دخول أو مفيش إنترنت).
  static Future<List<Post>?> syncRemote(List<Post> local) async {
    try {
      final h = await DriveAuth.headers();
      if (h == null) return null;
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'q': "appProperties has { key='$driveTag' and value='1' } "
            "and trashed=false",
        'fields': 'files(id,description,createdTime)',
        'orderBy': 'createdTime desc',
        'pageSize': '100',
      });
      final r = await http.get(uri, headers: h).timeout(
            const Duration(seconds: 12),
          );
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final hidden = await hiddenIds();
      final byId = {for (final p in local) p.id: p};
      for (final item in (j['files'] as List? ?? [])) {
        final m = item as Map;
        final id = m['id'].toString();
        if (hidden.contains(id) || byId.containsKey(id)) continue;
        final t = DateTime.tryParse(
              (m['createdTime'] ?? '').toString(),
            )?.millisecondsSinceEpoch ??
            0;
        byId[id] = Post(
          id: id,
          url: driveMediaUrl(id),
          caption: (m['description'] ?? '').toString(),
          time: t,
        );
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
// الرفع إلى Google Drive مع شريط تقدم
// ---------------------------------------------------------------

String _driveError(String body, int code) {
  try {
    final j = jsonDecode(body) as Map;
    final err = j['error'];
    if (err is Map && err['message'] != null) {
      return err['message'].toString();
    }
  } catch (_) {}
  return 'فشل الرفع ($code)';
}

String _mimeOf(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.mov')) return 'video/quicktime';
  if (p.endsWith('.webm')) return 'video/webm';
  if (p.endsWith('.mkv')) return 'video/x-matroska';
  if (p.endsWith('.3gp')) return 'video/3gpp';
  return 'video/mp4';
}

Future<String> _folderId(Map<String, String> h, {bool force = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('drive_folder');
  if (saved != null && !force) return saved;
  final r = await http.post(
    Uri.parse('https://www.googleapis.com/drive/v3/files?fields=id'),
    headers: {...h, 'Content-Type': 'application/json; charset=UTF-8'},
    body: jsonEncode({
      'name': driveFolderName,
      'mimeType': 'application/vnd.google-apps.folder',
    }),
  );
  if (r.statusCode != 200) {
    throw Exception(_driveError(utf8.decode(r.bodyBytes), r.statusCode));
  }
  final id = (jsonDecode(r.body) as Map)['id'].toString();
  await prefs.setString('drive_folder', id);
  return id;
}

Future<http.Response> _startSession(
  Map<String, String> h,
  String folder,
  File file,
  String caption,
  int len,
) {
  final mime = _mimeOf(file.path);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final ext = file.path.contains('.') ? file.path.split('.').last : 'mp4';
  return http.post(
    Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files'
      '?uploadType=resumable&fields=id,createdTime',
    ),
    headers: {
      ...h,
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Upload-Content-Type': mime,
      'X-Upload-Content-Length': '$len',
    },
    body: jsonEncode({
      'name': 'reel_$stamp.$ext',
      'description': caption,
      'parents': [folder],
      'appProperties': {driveTag: '1'},
    }),
  );
}

Future<Post> uploadVideo(
  File file,
  String caption,
  Map<String, String> h,
  void Function(double) onProgress,
) async {
  final len = await file.length();
  var folder = await _folderId(h);
  var start = await _startSession(h, folder, file, caption, len);
  if (start.statusCode == 404) {
    // المجلد اتحذف من Drive، نعمل واحد جديد
    folder = await _folderId(h, force: true);
    start = await _startSession(h, folder, file, caption, len);
  }
  if (start.statusCode != 200) {
    throw Exception(_driveError(utf8.decode(start.bodyBytes), start.statusCode));
  }
  final loc = start.headers['location'];
  if (loc == null) throw Exception('رد غير مفهوم من Drive');

  final req = http.StreamedRequest('PUT', Uri.parse(loc));
  req.headers['Content-Type'] = _mimeOf(file.path);
  req.contentLength = len;
  final respFuture = req.send();
  var sent = 0;
  file.openRead().listen(
    (chunk) {
      sent += chunk.length;
      onProgress(len == 0 ? 0 : sent / len);
      req.sink.add(chunk);
    },
    onDone: () => req.sink.close(),
    onError: (Object e) {
      req.sink.addError(e);
      req.sink.close();
    },
    cancelOnError: true,
  );
  final resp = await respFuture;
  final body = await resp.stream.bytesToString();
  if (resp.statusCode != 200 && resp.statusCode != 201) {
    throw Exception(_driveError(body, resp.statusCode));
  }
  final id = (jsonDecode(body) as Map)['id'].toString();
  return Post(
    id: id,
    url: driveMediaUrl(id),
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
  bool signedIn = DriveAuth.user != null;
  double? progress;
  bool uploading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    DriveAuth.ensure().then((a) {
      if (mounted) setState(() => signedIn = a != null);
    }).catchError((_) {});
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

  Future<void> account() async {
    await showDriveAccount(context);
    if (mounted) setState(() => signedIn = DriveAuth.user != null);
  }

  Future<void> publish() async {
    final f = file;
    if (f == null) {
      toast(context, 'اختار فيديو الأول');
      return;
    }
    setState(() {
      uploading = true;
      progress = 0;
      error = null;
    });
    try {
      final h = await DriveAuth.headers(interactive: true);
      if (h == null) throw Exception('لازم تسجّل دخول بحساب جوجل');
      if (mounted) setState(() => signedIn = true);
      final post = await uploadVideo(
        f,
        caption.text.trim(),
        h,
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
        error = friendlyError(e);
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
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: uploading ? null : account,
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
          if (!signedIn)
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
                    child: Text('سجّل دخول بحساب جوجل (Drive) مرة واحدة'),
                  ),
                  TextButton(
                    onPressed: account,
                    child: const Text('دخول'),
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
            'هيتشال من القائمة بس، والملف هيفضل في Google Drive.',
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

  Future<void> init({bool refresh = false}) async {
    if (failed) setState(() => failed = false);
    Map<String, String>? h;
    try {
      h = await DriveAuth.headers(refresh: refresh);
    } catch (_) {}
    final vc = VideoPlayerController.networkUrl(
      Uri.parse(widget.post.url),
      httpHeaders: h ?? const <String, String>{},
    );
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
            FilledButton(
              onPressed: () => init(refresh: true),
              child: const Text('إعادة المحاولة'),
            ),
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
              await Clipboard.setData(
                ClipboardData(
                  text: 'https://drive.google.com/file/d/${widget.post.id}/view',
                ),
              );
              if (context.mounted) toast(context, 'تم نسخ الرابط');
            }),
          ],
        ),
      ],
    );
  }
}

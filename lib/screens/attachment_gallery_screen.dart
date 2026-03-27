import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import '../core/theme.dart';

class AttachmentGalleryScreen extends StatefulWidget {
  const AttachmentGalleryScreen({super.key});

  @override
  State<AttachmentGalleryScreen> createState() =>
      _AttachmentGalleryScreenState();
}

class _AttachmentGalleryScreenState extends State<AttachmentGalleryScreen> {
  List<FileObject> _files = [];
  final Map<String, String> _signedUrlsByName = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) {
        if (!mounted) return;
        setState(() {
          _files = [];
          _signedUrlsByName.clear();
          _isLoading = false;
        });
        return;
      }

      final files =
          await supabase.storage.from('chat_attachments').list(path: userId);

      final imageFiles = files
          .where((f) =>
              f.name.endsWith('.jpg') ||
              f.name.endsWith('.jpeg') ||
              f.name.endsWith('.png'))
          .toList()
        ..sort((a, b) => (b.createdAt ?? '').compareTo(a.createdAt ?? ''));

      final signedUrls = <String, String>{};
      for (final file in imageFiles) {
        final objectPath = '$userId/${file.name}';
        try {
          final signedUrl = await supabase.storage
              .from('chat_attachments')
              .createSignedUrl(objectPath, 3600);
          signedUrls[file.name] = signedUrl;
        } catch (_) {
          // Skip files that cannot be signed right now.
        }
      }

      if (!mounted) return;
      setState(() {
        _files = imageFiles;
        _signedUrlsByName
          ..clear()
          ..addAll(signedUrls);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  void _openImage(String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        title: Text(
          'Galeri',
          style: GoogleFonts.orbitron(
            color: kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: kTextPrimary),
        actions: [
          IconButton(
            onPressed: () {
              setState(() => _isLoading = true);
              _loadFiles();
            },
            icon: const Icon(Icons.refresh, color: kTextSecondary),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: kAccentRed))
          : _files.isEmpty
              ? Center(
                  child: Text(
                    'Henüz gönderilen foto yok.',
                    style: GoogleFonts.orbitron(
                      color: kTextSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final url = _signedUrlsByName[file.name];
                    if (url == null || url.isEmpty) {
                      return Container(
                        decoration: BoxDecoration(
                          color: kBombBody,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.broken_image_outlined,
                          color: kTextSecondary,
                        ),
                      );
                    }
                    return GestureDetector(
                      onTap: () => _openImage(url),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: kBombBody,
                            child: const Icon(
                              Icons.broken_image_outlined,
                              color: kTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

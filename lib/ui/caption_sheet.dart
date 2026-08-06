import 'package:flutter/material.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../core/transcription/model_manager.dart';

/// Choices made in the caption sheet before a job starts.
class CaptionOptions {
  const CaptionOptions({
    required this.model,
    required this.language,
    required this.translateToEnglish,
  });

  final WhisperModel model;
  final String language;
  final bool translateToEnglish;
}

/// Lets the user pick model size and language before transcribing.
///
/// The model choice is the single biggest speed/accuracy lever, so it is
/// shown with real download sizes and installed status rather than hidden
/// in settings.
class CaptionSheet extends StatefulWidget {
  const CaptionSheet({
    super.key,
    required this.videoPath,
    required this.alreadyHasSubtitles,
  });

  final String videoPath;
  final bool alreadyHasSubtitles;

  @override
  State<CaptionSheet> createState() => _CaptionSheetState();
}

class _CaptionSheetState extends State<CaptionSheet> {
  final _models = ModelManager();

  WhisperModel _model = WhisperModel.base;
  String _language = 'en';
  bool _translate = false;

  List<WhisperModel> _installed = const [];

  /// Models offered in the picker. Larger variants exist but are impractical
  /// on phones, so the list stops at small plus the turbo model.
  static const _offered = [
    (WhisperModel.tiny, 'Tiny', 'Fastest, roughest'),
    (WhisperModel.base, 'Base', 'Good balance'),
    (WhisperModel.small, 'Small', 'Slower, more accurate'),
    (WhisperModel.largeV3Turbo, 'Turbo', 'Best quality, large download'),
  ];

  /// A pragmatic subset of Whisper's 99 languages, covering the most
  /// widely spoken ones. Auto-detect is the default.
  static const _languages = [
    ('auto', 'Detect automatically'),
    ('en', 'English'),
    ('es', 'Spanish'),
    ('hi', 'Hindi'),
    ('zh', 'Chinese'),
    ('ar', 'Arabic'),
    ('pt', 'Portuguese'),
    ('fr', 'French'),
    ('de', 'German'),
    ('ru', 'Russian'),
    ('ja', 'Japanese'),
    ('ko', 'Korean'),
    ('it', 'Italian'),
    ('tr', 'Turkish'),
  ];

  @override
  void initState() {
    super.initState();
    _loadInstalled();
  }

  Future<void> _loadInstalled() async {
    final installed = await _models.installedModels();
    if (mounted) setState(() => _installed = installed);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Generate captions',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Runs entirely on this device. Nothing is uploaded.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),

            if (widget.alreadyHasSubtitles) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.amber),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This video already has subtitles.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            const Text('Model', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),

            RadioGroup<WhisperModel>(
              groupValue: _model,
              onChanged: (v) => setState(() => _model = v ?? _model),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (model, name, blurb) in _offered)
                    RadioListTile<WhisperModel>(
                      value: model,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Row(
                        children: [
                          Text(name),
                          const SizedBox(width: 8),
                          if (_installed.contains(model))
                            const _Chip(label: 'Installed', color: Colors.green)
                          else
                            _Chip(
                              label:
                                  '${ModelManager.approximateSizesMb[model]} MB',
                              color: Colors.blueGrey,
                            ),
                        ],
                      ),
                      subtitle:
                          Text(blurb, style: const TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            const Text('Language',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),

            DropdownButtonFormField<String>(
              initialValue: _language,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                for (final (code, label) in _languages)
                  DropdownMenuItem(value: code, child: Text(label)),
              ],
              onChanged: (v) => setState(() => _language = v ?? 'en'),
            ),

            if (_language != 'en') ...[
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _translate,
                onChanged: (v) => setState(() => _translate = v ?? false),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Translate to English',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ],

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    CaptionOptions(
                      model: _model,
                      language: _language,
                      translateToEnglish: _translate,
                    ),
                  ),
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Generate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, height: 1.2),
      ),
    );
  }
}

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tactical UI sound layer. Plays short audio assets if present in
/// `assets/sounds/`; falls back to silent + haptic. User can disable
/// globally via SharedPreferences key `tekSoundEnabled` (default: true).
class TekSounds {
  TekSounds._();
  static final TekSounds instance = TekSounds._();

  final AudioPlayer _player = AudioPlayer();
  bool _enabled = true;
  bool _initialized = false;

  Future<void> ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('tekSoundEnabled') ?? true;
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('tekSoundEnabled', v);
    } catch (_) {}
  }

  bool get enabled => _enabled;

  Future<void> _play(String name) async {
    await ensureInit();
    if (!_enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$name'));
    } catch (_) {
      // Asset likely missing — silent fallback. Haptic at the call site provides texture.
    }
  }

  Future<void> tap() => _play('tap.mp3');
  Future<void> claimXp() => _play('claim_xp.mp3');
  Future<void> storyOpen() => _play('story_open.mp3');
  Future<void> transmission() => _play('transmission.mp3');
  Future<void> relay() => _play('relay.mp3');
  Future<void> redeem() => _play('redeem.mp3');
}

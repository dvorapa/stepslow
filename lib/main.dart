import 'package:flutter/material.dart';
import 'dart:collection' show SplayTreeMap;
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter_beep/flutter_beep.dart' show FlutterBeep;
import 'package:wakelock/wakelock.dart' show Wakelock;
import 'package:collection/collection.dart' show IterableExtension;
import 'package:volume_regulator/volume_regulator.dart' show VolumeRegulator;
import 'package:easy_dialogs/easy_dialogs.dart' show SingleChoiceDialog;
import 'package:typicons_flutter/typicons_flutter.dart' show Typicons;
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;
import 'package:yaml/yaml.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart' show FFmpegKit;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'pubspec.dart' show Pubspec;
import 'package:about/about.dart' show showMarkdownPage;
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import 'package:flutter/cupertino.dart' show CupertinoIcons;

/// Theme main color
final Color interactiveColor = Colors.orange[300]!; // #FFB74D #FFA726

/// Light theme color
const Color backgroundColor = Colors.white;

/// Special and YouTube components color
const Color redColor = Colors.red; // #E4273A

/// Text main color
final Color unfocusedColor = Colors.grey[400]!;

/// Dark theme color
const Color blackColor = Colors.black;

/// Duration initializer
Duration aemptyDuration = Duration.zero;

/// Default duration for empty queue
Duration adefaultDuration = const Duration(seconds: 5);

/// Default duration for animations
Duration aanimationDuration = const Duration(milliseconds: 300);

/// Default duration for animations
const Curve aanimationCurve = Curves.ease;

/// Available sources
final List<Source> asources = [Source('/storage/emulated/0', 0)];

/// List of completer bad states
// -1 for complete, -2 for error, natural for count
final List<int> abad = [0, -2];

/// Prints long messages, e.g. maps
void printLong(Object text) {
  text = text.toString();
  final Pattern pattern = RegExp('.{1,1023}');
  pattern
      .allMatches(text as String)
      .map((Match match) => match.group(0))
      .forEach(print);
}

/// Changes app data folders
bool adebug = false;

/// Pads seconds
String zero(int n) {
  if (n >= 10) return '$n';
  return '0$n';
}

/// Calculates height factor for wave
double aheightFactor(double aheight, int avolume, double avalue) =>
    aheight *
    (.81 - .56 * (1.0 - avolume / 100.0) - .25 * (1.0 - avalue / 100.0));

/// Filesystem entity representing a song or a folder.
class Entry implements Comparable<Entry> {
  /// Entry constructor
  Entry(this.path, this.type);

  /// Entry full path (contains filename)
  String path;

  /// Song or folder switch
  String type = 'song';

  /// Songs in folder count
  int songs = 0;

  @override
  int compareTo(Entry other) =>
      path.toLowerCase().compareTo(other.path.toLowerCase());

  @override
  String toString() => 'Entry( $path )';

  @override
  bool operator ==(Object other) => other is Entry && other.path == path;

  @override
  int get hashCode => path.hashCode;

  /// Entry name
  String get name {
    if (asources.any((Source asource) => asource.root == path)) return '';

    return path.split('/').lastWhere((String e) => e != '');
  }
}

/// Filesystem entity representing a source of songs.
class Source implements Pattern {
  /// Source constructor
  Source(this.root, this.id);

  /// Source root path
  String root;

  /// Order factor
  /// -1 for YouTube, 0 for Device, natural for others
  int id = 0;

  /// Stack of filesystem entities inside Source
  SplayTreeMap<Entry, SplayTreeMap> browse = SplayTreeMap();

  /// Source folder stack completer
  int browseFoldersComplete = 0;

  /// Source path to store covers
  String? coversPath;

  @override
  bool operator ==(Object other) => other is Source && other.root == root;

  @override
  int get hashCode => root.hashCode;

  @override
  Iterable<Match> allMatches(String string, [int start = 0]) =>
      root.allMatches(string, start);

  @override
  Match? matchAsPrefix(String string, [int start = 0]) =>
      root.matchAsPrefix(string, start);

  @override
  String toString() => 'Source( $root )';

  /// YouTube, internal or external device
  String get type {
    switch (id) {
      case 0:
        return 'Device';
      case -1:
        return 'YouTube';
      default:
        return 'SD card';
    }
  }

  /// Source name
  String get name {
    if (id <= 0) return type;
    return '$type $id';
  }
}

/// Lists subfolders of [root] path string
Stream<String> getFolders(String root) async* {
  await for (final FileSystemEntity subDir
      in Directory(root).list(recursive: true)) {
    try {
      final String subDirPath = subDir.path;
      if (subDir is Directory &&
          !subDirPath
              .split('/')
              .lastWhere((String e) => e != '')
              .startsWith('.')) {
        yield subDirPath;
      }
    } on FileSystemException {
      continue;
    }
  }
}

/// Finds SD card(s) if any and creates [Source] from them
Stream<Source> checkoutSdCards() async* {
  int n = 1;
  await for (final FileSystemEntity subDir in Directory('/storage').list()) {
    try {
      if (subDir is Directory && !await subDir.list().isEmpty) {
        yield Source(subDir.path, n);
        n++;
      }
    } on FileSystemException {
      continue;
    }
  }
}

/// Starts app
void main() => runApp(const Stepslow());

/// Stateless app entrypoint and theme initializer.
class Stepslow extends StatelessWidget {
  /// Stepslow constructor
  const Stepslow({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'Stepslow music player',
        theme: ThemeData(
            primaryColor: interactiveColor,
            appBarTheme: AppBarTheme(
                color: Colors.transparent,
                elevation: 0,
                iconTheme: IconThemeData(color: unfocusedColor),
                titleTextStyle: const TextStyle(color: blackColor),
                toolbarTextStyle: const TextStyle(color: blackColor)),
            colorScheme: ColorScheme.light(
                primary: interactiveColor,
                secondary: interactiveColor,
                onSecondary: backgroundColor),
            visualDensity: VisualDensity.adaptivePlatformDensity),
        home: const Player(title: 'Player'));
  }
}

/// Stateful app entrypoint.
class Player extends StatefulWidget {
  /// Player constructor
  const Player({Key? key, required this.title}) : super(key: key);

  /// Basic app title
  final String title;

  @override
  APlayerState createState() => APlayerState();
}

/// State handler.
class APlayerState extends State<Player> with WidgetsBindingObserver {
  /// Audio player entity
  final AudioPlayer audioPlayer = AudioPlayer();

  /// Android intent channel entity
  final MethodChannel bridge =
      const MethodChannel('cz.dvorapa.stepslow/sharedPath');

  /// Current playback state
  PlayerState astate = PlayerState.STOPPED;

  /// Current playback rate
  double arate = 100.0;

  /// Device volume
  int volume = 50;

  /// Device volume before change
  int apreCoverVolume = 50;

  /// Device volume before mute
  int apreMuteVolume = 50;

  /// Device volume before fade
  int apreFadeVolume = 0;

  /// Current playback position
  Duration aposition = aemptyDuration;

  /// Position to switch songs
  Duration afadePosition = aemptyDuration;

  /// Playback song from last run
  String? lastSongPath;

  /// Current playback mode
  String amode = 'loop';

  /// Current playback set
  String aset = 'random';

  late Orientation aorientation;

  /// False if [volume] picker should be hidden
  bool ashowVolumePicker = false;

  /// False if [ashowVolumePicker] was false at last redraw
  bool apreCoverVolumePicker = false;

  /// Timer to release [ashowVolumePicker]
  Timer? avolumeCoverTimer;

  /// Prelude length before playback
  int aintroLength = 0;

  /// Random generator to shuffle queue after startup
  final Random random = Random();

  /// History of page transitions
  List<int> pageHistory = [2];

  /// [PageView] controller
  final PageController acontroller = PageController(initialPage: 2);

  /// Current playback source
  Source source = asources[0];

  /// Current playback folder
  String folder = '/storage/emulated/0/Music';

  /// Chosen playback folder
  String chosenFolder = '/storage/emulated/0/Music';

  /// Current playback song
  SongModel? song;

  /// Playback song before change
  SongModel? apreviousSong;

  /// Current song index in queue
  int index = 0;

  /// Current song duration
  Duration duration = aemptyDuration;

  /// Source cover stack completer
  int acoversComplete = 0;

  /// File containing album artwork paths YAML map
  File? acoversFile;

  /// YAML map of album artwork paths
  List<String> acoversYaml = ['---'];

  /// Map representation of album artwork paths YAML map
  Map<String, int> acoversMap = {};

  /// Queue completer
  int aqueueComplete = 0;

  /// Queue completer
  int atempQueueComplete = 0;

  /// Song stack completer
  int asongsComplete = 0;

  /// Source stack completer
  int abrowseComplete = 0;

  /// Source song stack completer
  int abrowseSongsComplete = 0;

  /// Current playback queue
  final List<SongModel> queue = [];

  /// Current playback queue
  final List<SongModel> atempQueue = [];

  /// Stack of available songs
  final List<SongModel> asongs = [];

  /// Text to speech timer
  Timer? attsTimer;

  /// Fade timer
  Timer? afadeTimer;

  /// Initializes [song] playback
  void onPlay({bool quiet = false}) {
    if (astate == PlayerState.PAUSED || quiet) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      final String asongPath = song!.data;
      if (aintroLength != 0) {
        onStop(quiet: true);
        audioPlayer.setUrl(asongPath, isLocal: true);
      }
      final List<int> arange = [for (int i = aintroLength; i > 0; i--) i];
      attsTimer?.cancel();
      if (arange.isEmpty) {
        audioPlayer.play(asongPath, isLocal: true);
      } else {
        attsTimer = Timer.periodic(const Duration(seconds: 1), (a) {
          if (arange.length > 1) {
            FlutterBeep.playSysSound(Platform.isAndroid ? 24 : 1052);
            arange.removeAt(0);
          } else if (arange.length == 1) {
            arange.removeAt(0);
          } else {
            audioPlayer.play(asongPath, isLocal: true);
            attsTimer!.cancel();
          }
        });
      }
      setState(() => lastSongPath = asongPath);
      asetValue('lastSongPath', asongPath);
    }
    onRate(arate);
    if (!quiet) setState(() => astate = PlayerState.PLAYING);
    Wakelock.enable();
  }

  /// Changes [song] according to given [aindex]
  void onChange(int aindex) {
    final int available = queue.length;
    setState(() {
      if (aindex < 0) {
        index = aindex + available;
        if (aset == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else if (aindex >= available) {
        index = aindex - available;
        if (aset == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else {
        index = aindex;
      }
    });
    if (astate == PlayerState.PLAYING) {
      onPlay();
    } else {
      onStop();
      setState(() {
        song = queue.isNotEmpty ? queue[index] : null;
        aposition = aemptyDuration;
        if (song != null) duration = Duration(milliseconds: song!.duration!);
      });
      if (song != null) {
        final String asongPath = song!.data;
        setState(() => lastSongPath = asongPath);
        asetValue('lastSongPath', asongPath);
      }
    }
  }

  /// Pauses [song] playback
  void onPause({bool quiet = false}) {
    attsTimer?.cancel();
    audioPlayer.pause();
    if (!quiet) setState(() => astate = PlayerState.PAUSED);
    if (apreFadeVolume != 0) {
      afadeTimer!.cancel();
      onChange(index + 1);
      onVolume(apreFadeVolume);
      setState(() => apreFadeVolume = 0);
    }
  }

  /// Shuts player down and resets its state
  void onStop({bool quiet = false}) {
    audioPlayer.stop();
    setState(() {
      if (!quiet) {
        duration = aemptyDuration;
        aposition = aemptyDuration;
      }
      astate = PlayerState.STOPPED;
    });
    Wakelock.disable();
  }

  /// Changes [folder] according to given
  void onFolder(String afolder) {
    if (folder != afolder) {
      queue.clear();
      setState(() {
        index = 0;
        aqueueComplete = 0;
      });
      if (!abad.contains(asongsComplete)) {
        for (final SongModel asong in asongs) {
          if (File(asong.data).parent.path == afolder) {
            if (aset != 'random' || [0, 1].contains(aqueueComplete)) {
              queue.add(asong);
            } else {
              queue.insert(1 + random.nextInt(aqueueComplete), asong);
            }
            setState(() => ++aqueueComplete);

            if (aqueueComplete == 1) {
              onRate(100.0);
              onChange(index);
            }
          }
        }
        if (aqueueComplete > 0) {
          setState(() => aqueueComplete = -1);
        } else {
          onStop();
          setState(() => song = null);
          if (acontroller.page! > .1) apickFolder();
        }
      }
      setState(() {
        folder = afolder;
        chosenFolder = afolder;
        aintroLength = 0;
      });
    }
  }

  /// Creates temporary queue list
  void agetTempQueue(String atempFolder) {
    if (chosenFolder != atempFolder) {
      setState(() {
        chosenFolder = atempFolder;
        atempQueueComplete = 0;
      });
      atempQueue.clear();
      if (!abad.contains(asongsComplete)) {
        for (final SongModel asong in asongs) {
          if (File(asong.data).parent.path == atempFolder) {
            atempQueue.add(asong);
            setState(() => ++atempQueueComplete);
          }
        }
      }
      setState(() => atempQueueComplete = -1);
    }
  }

  /// Initializes shared or saved [song] playback
  Future<void> loadSpecificSong() async {
    final String? asharedPath = await bridge.invokeMethod('openSharedPath');
    final String? apath = asharedPath ?? lastSongPath;
    if (apath != null && apath != song?.data) {
      final String anewFolder = File(apath).parent.path;
      final Source anewSource =
          asources.firstWhereOrNull(anewFolder.startsWith) ?? source;
      if (source != anewSource) setState(() => source = anewSource);
      onFolder(anewFolder);
      final int aindex =
          queue.indexWhere((SongModel asong) => asong.data == apath);
      onChange(aindex);
      if (asharedPath != null) onPlay();
    }
  }

  /// Changes playback [amode] and informs user using given [context]
  void onMode(StatelessElement context) {
    setState(() => amode = amode == 'loop' ? 'once' : 'loop');
    asetValue('amode', amode);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.secondary,
        elevation: 0,
        duration: const Duration(seconds: 2),
        content:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Text(amode == 'loop' ? 'playing in a loop ' : 'playing once ',
              style:
                  TextStyle(color: Theme.of(context).colorScheme.onSecondary)),
          Icon(amode == 'loop' ? Icons.repeat : Icons.trending_flat,
              color: Theme.of(context).colorScheme.onSecondary, size: 20.0)
        ])));
  }

  /// Changes playback [aset] and informs user using given [context]
  void onSet(StatelessElement context) {
    setState(() {
      switch (aset) {
        case '1':
          aset = 'all';
          break;
        case 'all':
          queue.shuffle();

          if (song != null) index = queue.indexOf(song!);
          aset = 'random';

          break;
        default:
          queue.sort((SongModel a, SongModel b) => a.data.compareTo(b.data));

          if (song != null) index = queue.indexOf(song!);
          aset = '1';

          break;
      }
    });
    asetValue('aset', aset);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.secondary,
        elevation: 0,
        duration: const Duration(seconds: 2),
        content:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Icon(astatus(aset),
              color: Theme.of(context).colorScheme.onSecondary, size: 20.0),
          Text(aset == '1' ? ' playing 1 song' : ' playing $aset songs',
              style:
                  TextStyle(color: Theme.of(context).colorScheme.onSecondary))
        ])));
  }

  /// Starts to listen seek drag actions
  void onPositionDragStart(
      BuildContext context, DragStartDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    if (astate == PlayerState.PLAYING) onPause(quiet: true);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Listens seek drag actions
  void onPositionDragUpdate(
      BuildContext context, DragUpdateDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Ends to listen seek drag actions
  void onPositionDragEnd(
      BuildContext context, DragEndDetails details, Duration duration) {
    if (astate == PlayerState.PLAYING) onPlay(quiet: true);
  }

  /// Listens seek tap actions
  void onPositionTapUp(
      BuildContext context, TapUpDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Changes [aposition] according to seek actions
  void onSeek(Offset position, Duration duration, double width) {
    double newPosition = 0;

    if (position.dx <= 0) {
      newPosition = 0;
    } else if (position.dx >= width) {
      newPosition = width;
    } else {
      newPosition = position.dx;
    }

    setState(() => aposition = duration * (newPosition / width));

    audioPlayer.seek(aposition * (arate / 100.0));
  }

  /// Starts to listen [volume] drag actions
  void onVolumeDragStart(BuildContext context, DragStartDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset avolume = slider.globalToLocal(details.globalPosition);
    updateVolume(avolume, slider.constraints.biggest.height);
  }

  /// Listens [volume] drag actions
  void onVolumeDragUpdate(BuildContext context, DragUpdateDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset avolume = slider.globalToLocal(details.globalPosition);
    updateVolume(avolume, slider.constraints.biggest.height);
  }

  /// Changes playback [volume] according to given offset
  void updateVolume(Offset avolume, double height) {
    double newVolume = 50.0;

    if (avolume.dy <= .19 * height) {
      newVolume = 0;
    } else if (avolume.dy >= height) {
      newVolume = .81 * height;
    } else {
      newVolume = avolume.dy - .19 * height;
    }

    newVolume = 100.0 * (1 - (newVolume / (.81 * height)));
    onVolume(newVolume.floor());
  }

  /// Changes playback [volume] by given
  void onVolume(int avolume) async {
    if (avolume > 100) {
      avolume = 100;
    } else if (avolume < 0) {
      avolume = 0;
    }
    VolumeRegulator.setVolume(avolume);
    setState(() => volume = avolume);
    asetValue('volume', avolume);
  }

  /// Changes playback [arate] by given
  void onRate(double rate) {
    if (rate > 200.0) {
      rate = 200.0;
    } else if (rate < 5.0) {
      rate = 5.0;
    }
    audioPlayer.setPlaybackRate(rate / 100.0);
    setState(() {
      aposition = aposition * (arate / rate);
      duration = duration * (arate / rate);
      arate = rate;
    });
  }

  /// Switches playback [aprelude]
  void onPrelude() {
    setState(() => aintroLength = aintroLength == 0 ? 10 : 0);
    if (aintroLength == 10) onChange(index);
  }

  /// Switches playback [astate]
  void achangeState() => astate == PlayerState.PLAYING ? onPause() : onPlay();

  /// Shows dialog to pick [source]
  void apickSource() {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return SingleChoiceDialog<Source>(
              isDividerEnabled: true,
              items: asources,
              onSelected: (Source asource) {
                setState(() => source = asource);
                onFolder(asource.root);
              },
              itemBuilder: (Source asource) {
                final Text asourceText = source == asource
                    ? Text(asource.name,
                        style: TextStyle(color: Theme.of(context).primaryColor))
                    : Text(asource.name);
                switch (asource.id) {
                  case -1:
                    return atextButtonLink(
                        icon: Icon(Typicons.social_youtube,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : redColor),
                        label: asourceText);
                  case 0:
                    return atextButtonLink(
                        icon: Icon(Icons.phone_iphone,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)),
                        label: asourceText);
                  default:
                    return atextButtonLink(
                        icon: Icon(Icons.sd_card,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)),
                        label: asourceText);
                }
              });
        });
  }

  /// Navigates to folder picker page
  void apickFolder() => acontroller.animateToPage(0,
      duration: aanimationDuration, curve: aanimationCurve);

  /// Navigates to song picker page
  void apickSong() => acontroller.animateToPage(1,
      duration: aanimationDuration, curve: aanimationCurve);

  /// Navigates to player main page
  void areturnToPlayer() => acontroller.animateToPage(2,
      duration: aanimationDuration, curve: aanimationCurve);

  /// Navigates to features page
  void auseFeatures() => acontroller.animateToPage(3,
      duration: aanimationDuration, curve: aanimationCurve);

  /// Goes back to the previous page
  bool onBack() {
    if (1.9 < acontroller.page! && acontroller.page! < 2.1) {
      setState(() => pageHistory = [2]);
      return true;
    }
    acontroller.animateToPage(pageHistory[0],
        duration: aanimationDuration, curve: aanimationCurve);
    setState(() => pageHistory = [2]);
    return false;
  }

  /// Get cached or preferred value
  void agetSavedValues() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    int avolume = await VolumeRegulator.getVolume();
    setState(() {
      lastSongPath = prefs.getString('lastSongPath');
      amode = prefs.getString('amode') ?? 'loop';
      aset = prefs.getString('aset') ?? 'random';
      volume = prefs.getInt('volume') ?? avolume;
    });
    await prefs.setString('amode', amode);
    await prefs.setString('aset', aset);
  }

  /// Save cached or preferred value
  Future<void> asetValue(String variable, dynamic value) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(variable, value);
    if (value is double) await prefs.setDouble(variable, value);
    if (value is int) await prefs.setInt(variable, value);
  }

  /// Queries album artworks to app cache
  Future<void> aloadCoversMap() async {
    if (acoversComplete == 0) {
      if (!acoversFile!.existsSync()) {
        await acreateCoversMap();
      } else {
        try {
          acoversYaml = await acoversFile!.readAsLines();
          acoversMap = Map<String, int>.from(
              loadYaml(acoversYaml.join('\n')) ?? const {});
          setState(() => acoversComplete = -1);
        } on FileSystemException catch (error) {
          print(error);
          await acreateCoversMap();
        } on YamlException catch (error) {
          print(error);
          await acreateCoversMap();
        }
      }
    }
  }

  /// Fixes album artworks cache
  Future<void> afixCoversMap() async {
    if (acoversComplete == -1) {
      setState(() => acoversComplete = 0);
      await acreateCoversMap();
    }
  }

  /// Queries album artworks to phone cache
  Future<void> acreateCoversMap() async {
    acoversYaml = ['---'];
    acoversMap.clear();
    for (final SongModel asong in asongs) {
      final String asongPath = asong.data;
      final String acoversPath =
          (asources.firstWhereOrNull(asongPath.startsWith)?.coversPath ??
              asources[0].coversPath)!;
      final String acoverPath = '$acoversPath/${asongPath.hashCode}.jpg';
      int astatus = 0;
      if (!File(acoverPath).existsSync()) {
        final int aheight =
            (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
        FFmpegKit.execute(
                '-i "$asongPath" -vf scale="-2:\'min($aheight,ih)\'":flags=lanczos -an "$acoverPath"')
            .then((session) async {
          final returnCode = await session.getReturnCode();
          astatus = returnCode!.getValue();
          final String? failStackTrace = await session.getFailStackTrace();
          if (failStackTrace != null && failStackTrace.isNotEmpty)
            print(failStackTrace);
        }, onError: (error) {
          print(error.stackTrace);
          setState(() => acoversComplete = -2);
          return 1;
        });
      }
      acoversMap[asongPath] = astatus;
      acoversYaml.add('"$asongPath": $astatus');
      setState(() => ++acoversComplete);
    }
    await acacheCoversMap();
  }

  /// Writes app cache into a file
  Future<void> acacheCoversMap() async {
    await acoversFile!.writeAsString(acoversYaml.join('\n'));
    setState(() => acoversComplete = -1);
  }

  /// Gets album artwork from cache
  Image? agetCover(SongModel asong) {
    final String asongPath = asong.data;
    if (acoversMap.containsKey(asongPath)) {
      if (acoversMap[asongPath] == 0) {
        final String acoversPath =
            (asources.firstWhereOrNull(asongPath.startsWith)?.coversPath ??
                asources[0].coversPath)!;
        final File acoverFile = File('$acoversPath/${asongPath.hashCode}.jpg');
        if (acoverFile.existsSync()) {
          return Image.file(acoverFile, fit: BoxFit.cover);
          /*} else {
            WidgetsBinding.instance.addPostFrameCallback((_) => afixCover(asong));*/
        }
      }
    } else {
      afixCoversMap();
    }
    return null;
  }

  /// Fixes album artwork in cache
  Future<void> afixCover(SongModel asong) async {
    if (acoversComplete == -1) {
      setState(() => acoversComplete = 0);
      final String asongPath = asong.data;
      final String acoversPath =
          (asources.firstWhereOrNull(asongPath.startsWith)?.coversPath ??
              asources[0].coversPath)!;
      final String acoverPath = '$acoversPath/${asongPath.hashCode}.jpg';
      int astatus = 0;
      final int aheight =
          (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
      FFmpegKit.execute(
              '-i "$asongPath" -vf scale="-2:\'min($aheight,ih)\'":flags=lanczos -an "$acoverPath"')
          .then((session) async {
        final returnCode = await session.getReturnCode();
        astatus = returnCode!.getValue();
        final String? failStackTrace = await session.getFailStackTrace();
        if (failStackTrace != null && failStackTrace.isNotEmpty)
          print(failStackTrace);
      }, onError: (error) {
        print(error.stackTrace);
        setState(() => acoversComplete = -2);
        return 1;
      });
      acoversMap[asongPath] = astatus;
      setState(() => ++acoversComplete);
      acoversYaml = ['---'];
      acoversMap.forEach((String acoverSong, int acoverStatus) =>
          acoversYaml.add('"$acoverSong": $acoverStatus'));
      await acacheCoversMap();
    }
  }

  /// Gets relative urls for [fillBrowse]
  Iterable<int> getRelatives(String root, String path) {
    final int arootLength = root.length;
    String relative = path.substring(arootLength);
    if (relative.startsWith('/')) relative = '${relative.substring(1)}/';
    return '/'.allMatches(relative).map((Match m) => arootLength + m.end);
  }

  /// Fills [browse] stack with given [apath]
  void fillBrowse(
      String apath,
      String aroot,
      SplayTreeMap<Entry, SplayTreeMap> browse,
      int value,
      ValueChanged<int> valueChanged,
      String type) {
    final Iterable<int> relatives = getRelatives(aroot, apath);
    int j = 0;
    String relativeString;
    num length = type == 'song' ? relatives.length - 1 : relatives.length;
    if (length == 0) length = .5;
    while (j < length) {
      relativeString =
          length == .5 ? aroot : apath.substring(0, relatives.elementAt(j));
      Entry entry = Entry(relativeString, type);
      if (browse.containsKey(entry)) {
        entry = browse.keys.firstWhere((Entry key) => key == entry);
      } else {
        browse[entry] = SplayTreeMap<Entry, SplayTreeMap>();
        if (value != -2) setState(() => valueChanged(++value));
      }
      if (type == 'song') entry.songs++;
      browse = browse[entry] as SplayTreeMap<Entry, SplayTreeMap>;
      j++;
    }
  }

  @override
  void initState() {
    agetSavedValues();

    audioPlayer.onDurationChanged.listen((Duration d) {
      setState(() => duration = d * (100.0 / arate));
    });
    audioPlayer.onAudioPositionChanged.listen((Duration p) {
      setState(() => aposition = p * (100.0 / arate));
      if (afadePosition > aemptyDuration &&
          aposition > afadePosition &&
          apreFadeVolume == 0 &&
          astate == PlayerState.PLAYING) {
        setState(() => apreFadeVolume = volume);
        afadeTimer = Timer.periodic(const Duration(milliseconds: 100), (a) {
          if (volume > 0) {
            onVolume(volume - 1);
          } else {
            afadeTimer!.cancel();
            onChange(index + 1);
            onVolume(apreFadeVolume);
            setState(() => apreFadeVolume = 0);
          }
        });
      }
    });
    audioPlayer.onPlayerCompletion.listen((a) {
      setState(() => aposition = duration);
      if (amode == 'once' && (aset == '1' || index == queue.length - 1)) {
        onStop();
      } else if (aset == '1') {
        onPlay();
      } else {
        onChange(index + 1);
      }
    });
    audioPlayer.onPlayerError.listen((String error) {
      onStop();
      print(error);
    });

    VolumeRegulator.volumeStream.listen((int v) {
      setState(() => volume = v);
      asetValue('volume', v);
    });

    acontroller.addListener(() {
      final double amodulo = acontroller.page! % 1;
      if (.9 < amodulo || amodulo < .1) {
        final int apage = acontroller.page!.round();
        if (!pageHistory.contains(apage)) {
          pageHistory.add(apage);
          while (pageHistory.length > 2) pageHistory.removeAt(0);
        }
      }
    });

    super.initState();

    Permission.storage.request().then((PermissionStatus astatus) {
      if (astatus == PermissionStatus.permanentlyDenied) {
        openAppSettings();
      } else if (astatus == PermissionStatus.denied) {
        SystemChannels.platform.invokeMethod('SystemNavigator.pop');
      }
      // Got permission (read user files and folders)
      checkoutSdCards().listen(asources.add,
          onDone: () {
            // Got asources
            Stream<List<SongModel>>.fromFuture(OnAudioQuery().querySongs())
                .expand((List<SongModel> asongs) => asongs)
                .listen((SongModel asong) {
              final String asongPath = asong.data;
              // queue
              if (File(asongPath).parent.path == folder) {
                if (aset != 'random' || [0, 1].contains(aqueueComplete)) {
                  queue.add(asong);
                } else {
                  queue.insert(1 + random.nextInt(aqueueComplete), asong);
                }
                setState(() => ++aqueueComplete);
                if (aqueueComplete == 1) {
                  audioPlayer.setUrl(asongPath, isLocal: true);
                  setState(() => song = queue[0]);
                }
              }

              if (asources.any(asongPath.startsWith)) {
                // asongs
                asongs.add(asong);
                setState(() => ++asongsComplete);

                // browse
                final Source asource =
                    asources.firstWhere(asongPath.startsWith);
                fillBrowse(
                    asongPath,
                    asource.root,
                    asource.browse,
                    abrowseSongsComplete,
                    (value) => abrowseSongsComplete = value,
                    'song');
              }
            }, onDone: () {
              // Got queue, asongs, browse
              setState(() {
                aqueueComplete = aqueueComplete > 0 ? -1 : 0;
                asongsComplete = asongsComplete > 0 ? -1 : 0;
                if (asources.every(
                    (Source asource) => asource.browseFoldersComplete == -1))
                  abrowseComplete = -1;
                abrowseSongsComplete = abrowseSongsComplete > 0 ? -1 : 0;
              });
              if (asongsComplete == -1 &&
                  acoversFile != null &&
                  !asources.any((Source asource) => asource.coversPath == null))
                aloadCoversMap();
            }, onError: (error) {
              setState(() {
                aqueueComplete = -2;
                asongsComplete = -2;
                abrowseComplete = -2;
                abrowseSongsComplete = -2;
              });
              print(error.stackTrace);
            });

            for (final Source asource in asources) {
              getFolders(asource.root).listen((String afolderPath) {
                fillBrowse(
                    afolderPath,
                    asource.root,
                    asource.browse,
                    asource.browseFoldersComplete,
                    (value) => asource.browseFoldersComplete = value,
                    'folder');
              }, onDone: () {
                fillBrowse(
                    asource.root,
                    asource.root,
                    asource.browse,
                    asource.browseFoldersComplete,
                    (value) => asource.browseFoldersComplete = value,
                    'folder');
                // Got folders
                setState(() {
                  asource.browseFoldersComplete = -1;
                  if ((abrowseSongsComplete == -1) &&
                      asources.every((Source asource) =>
                          asource.browseFoldersComplete == -1))
                    abrowseComplete = -1;
                });
                loadSpecificSong();
                WidgetsBinding.instance.addObserver(this);
              }, onError: (error) {
                setState(() {
                  abrowseComplete = -2;
                  asource.browseFoldersComplete = -2;
                });
                print(error.stackTrace);
              });
            }

            getTemporaryDirectory().then((Directory aappCache) {
              final String aappCachePath = aappCache.path;
              for (final Source asource in asources)
                asource.coversPath = aappCachePath;

              if (Platform.isAndroid) {
                Stream<List<Directory>?>.fromFuture(
                        getExternalCacheDirectories())
                    .expand((List<Directory>? aextCaches) => aextCaches!)
                    .listen((Directory aextCache) {
                  final String aextCachePath = aextCache.path;
                  if (!aextCachePath.startsWith(asources[0])) {
                    asources.firstWhere(aextCachePath.startsWith).coversPath =
                        aextCachePath;
                  } else if (adebug) {
                    asources[0].coversPath = aextCachePath;
                  }
                }, onDone: () {
                  // Got coversPath
                  if (asongsComplete == -1 && acoversFile != null)
                    aloadCoversMap();
                }, onError: (error) => print(error.stackTrace));
              } else {
                if (asongsComplete == -1 && acoversFile != null)
                  aloadCoversMap();
              }
            }, onError: (error) => print(error.stackTrace));
          },
          onError: (error) => print(error.stackTrace));
    }, onError: (error) => print(error.stackTrace));

    /*Stream<List<InternetAddress>>.fromFuture(
            InternetAddress.lookup('youtube.com'))
        .expand((List<InternetAddress> aaddresses) => aaddresses)
        .firstWhere(
            (InternetAddress aaddress) => aaddress.rawAddress.isNotEmpty)
        .then((a) => asources.add(Source('', -1)),
            onError: (error) => print(error.stackTrace));*/
    // Got YouTube

    getApplicationSupportDirectory().then((Directory aappData) {
      acoversFile = File('${aappData.path}/covers.yaml');

      if (Platform.isAndroid && adebug) {
        late StreamSubscription<Directory> aextDataStream;
        aextDataStream =
            Stream<List<Directory>?>.fromFuture(getExternalStorageDirectories())
                .expand((List<Directory>? aextDatas) => aextDatas!)
                .listen((Directory aextData) {
          final String aextDataPath = aextData.path;
          if (aextDataPath.startsWith(asources[0])) {
            acoversFile = File('$aextDataPath/covers.yaml');
            // Got acoversFile
            if (asongsComplete == -1 &&
                !asources.any((Source asource) => asource.coversPath == null))
              aloadCoversMap();
            aextDataStream.cancel();
          }
        }, onError: (error) => print(error.stackTrace));
      } else {
        if (asongsComplete == -1 &&
            !asources.any((Source asource) => asource.coversPath == null))
          aloadCoversMap();
      }
    }, onError: (error) => print(error.stackTrace));
  }

  @override
  void dispose() {
    audioPlayer.release();
    FFmpegKit.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) loadSpecificSong();
  }

  @override
  Widget build(BuildContext context) {
    if (apreCoverVolume != volume) {
      ashowVolumePicker = true;
      apreCoverVolume = volume;
      avolumeCoverTimer?.cancel();
      avolumeCoverTimer = Timer(adefaultDuration, () {
        setState(() => ashowVolumePicker = false);
      });
    }
    if (apreviousSong != song) {
      ashowVolumePicker = false;
      apreviousSong = song;
      avolumeCoverTimer?.cancel();
    }
    if (apreCoverVolumePicker != ashowVolumePicker) {
      avolumeCoverTimer?.cancel();
      avolumeCoverTimer = Timer(adefaultDuration, () {
        setState(() => ashowVolumePicker = false);
      });
    }
    apreCoverVolumePicker = ashowVolumePicker;
    aorientation = MediaQuery.of(context).orientation;
    return Material(
        child: PageView(
            controller: acontroller,
            physics: const BouncingScrollPhysics(),
            children: <WillPopScope>[
          // folders
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          tooltip: 'Change source',
                          onPressed: apickSource,
                          icon: asourceButton(
                              source.id,
                              Theme.of(context)
                                  .textTheme
                                  .bodyText2!
                                  .color!
                                  .withOpacity(.55))),
                      title: Tooltip(
                          message: 'Change source',
                          child: InkWell(
                              onTap: apickSource, child: Text(source.name))),
                      actions: ashowContents(this)),
                  body: afolderPicker(this))),
          // songs
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: chosenFolder != folder
                          ? IconButton(
                              onPressed: apickFolder,
                              tooltip: 'Pick different folder',
                              icon: const Icon(Icons.navigate_before))
                          : IconButton(
                              onPressed: apickFolder,
                              tooltip: 'Pick different folder',
                              icon: queue.isNotEmpty
                                  ? const Icon(Typicons.folder_open)
                                  : Icon(Icons.create_new_folder_outlined,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyText2!
                                          .color!
                                          .withOpacity(.55))),
                      title: anavigation(this)),
                  body: asongPicker(this),
                  floatingActionButton: Align(
                      alignment: const Alignment(.8, .8),
                      child: Transform.scale(
                          scale: 1.1,
                          child: chosenFolder != folder
                              ? FloatingActionButton(
                                  onPressed: () {
                                    onFolder(chosenFolder);
                                    if (queue.isNotEmpty) {
                                      setState(() => index = 0);
                                      onPlay();
                                      areturnToPlayer();
                                    }
                                  },
                                  tooltip: atempQueueComplete == -1
                                      ? 'Play chosen folder'
                                      : 'Loading...',
                                  shape: aorientation == Orientation.portrait
                                      ? const ACubistShapeB()
                                      : const ACubistShapeD(),
                                  elevation: 6.0,
                                  child: atempQueueComplete == -1
                                      ? const Icon(Icons.play_arrow, size: 32.0)
                                      : SizedBox(
                                          width: 22.0,
                                          height: 22.0,
                                          child: CircularProgressIndicator(
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary))))
                              : aplay(this, 6.0, 32.0, () {
                                  achangeState();
                                  if (astate == PlayerState.PLAYING)
                                    areturnToPlayer();
                                }))))),
          // player
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: apickFolder,
                          tooltip: 'Pick different folder',
                          icon: queue.isNotEmpty
                              ? const Icon(Typicons.folder_open)
                              : Icon(Icons.create_new_folder_outlined,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodyText2!
                                      .color!
                                      .withOpacity(.55))),
                      actions: <IconButton>[
                        IconButton(
                            onPressed: auseFeatures,
                            tooltip: 'Try special features',
                            icon: Icon(Icons.auto_fix_normal,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)))
                      ]),
                  body: aorientation == Orientation.portrait
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Flexible>[
                              Flexible(
                                  flex: 17,
                                  child: FractionallySizedBox(
                                      widthFactor: .45,
                                      child: aplayerSquared(this))),
                              Flexible(
                                  flex: 11,
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        aintroLength == 0
                                            ? const SizedBox.shrink()
                                            : GestureDetector(
                                                onDoubleTap: onPrelude,
                                                child: FractionallySizedBox(
                                                    heightFactor: aheightFactor(
                                                        1,
                                                        volume,
                                                        wave(song?.title ?? 'zapaz')
                                                            .first),
                                                    child: Container(
                                                        alignment:
                                                            Alignment.center,
                                                        padding: const EdgeInsets
                                                                .symmetric(
                                                            horizontal: 12.0),
                                                        color: redColor,
                                                        child: Text(
                                                            '$aintroLength s',
                                                            style: TextStyle(
                                                                color: Theme.of(
                                                                        context)
                                                                    .scaffoldBackgroundColor))))),
                                        Expanded(child: aplayerOblong(this))
                                      ])),
                              Flexible(
                                  flex: 20,
                                  child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          16.0, 12.0, 16.0, 0),
                                      color: Theme.of(context).primaryColor,
                                      child: Theme(
                                          data: ThemeData.from(
                                              colorScheme: Theme.of(context)
                                                  .colorScheme
                                                  .copyWith(
                                                      secondary: Theme.of(
                                                              context)
                                                          .scaffoldBackgroundColor,
                                                      onSecondary:
                                                          Theme.of(context)
                                                              .primaryColor,
                                                      brightness:
                                                          Brightness.dark)),
                                          child: aplayerControl(this))))
                            ])
                      : Column(children: <Flexible>[
                          Flexible(
                              flex: 3,
                              child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: <Widget>[
                                    SizedBox(
                                        width:
                                            MediaQuery.of(context).size.width *
                                                .37,
                                        child: Theme(
                                            data: Theme.of(context).copyWith(
                                                textTheme: Theme.of(context)
                                                    .textTheme
                                                    .apply(
                                                        bodyColor:
                                                            Theme.of(context)
                                                                .primaryColor),
                                                iconTheme: IconThemeData(
                                                    color: Theme.of(context)
                                                        .primaryColor)),
                                            child: aplayerControl(this))),
                                    aplayerSquared(this)
                                  ])),
                          Flexible(
                              flex: 2,
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    FractionallySizedBox(
                                        heightFactor: aheightFactor(1, volume,
                                            wave(song?.title ?? 'zapaz').first),
                                        child: Container(
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12.0),
                                            color: aposition == aemptyDuration
                                                ? Theme.of(context)
                                                    .primaryColor
                                                    .withOpacity(.7)
                                                : Theme.of(context)
                                                    .primaryColor,
                                            child: Text(
                                                atimeInfo(
                                                    aqueueComplete, aposition),
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .scaffoldBackgroundColor,
                                                    fontWeight:
                                                        FontWeight.bold)))),
                                    aintroLength == 0
                                        ? const SizedBox.shrink()
                                        : GestureDetector(
                                            onDoubleTap: onPrelude,
                                            child: FractionallySizedBox(
                                                heightFactor: aheightFactor(
                                                    1,
                                                    volume,
                                                    wave(song?.title ?? 'zapaz')
                                                        .first),
                                                child: Container(
                                                    alignment: Alignment.center,
                                                    padding: const EdgeInsets
                                                            .symmetric(
                                                        horizontal: 12.0),
                                                    color: redColor,
                                                    child: Text(
                                                        '$aintroLength s',
                                                        style: TextStyle(
                                                            color: Theme.of(
                                                                    context)
                                                                .scaffoldBackgroundColor))))),
                                    Expanded(child: aplayerOblong(this)),
                                    FractionallySizedBox(
                                        heightFactor: aheightFactor(1, volume,
                                            wave(song?.title ?? 'zapaz').last),
                                        child: Container(
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12.0),
                                            color: aposition == duration &&
                                                    duration != aemptyDuration
                                                ? Theme.of(context).primaryColor
                                                : Theme.of(context)
                                                    .primaryColor
                                                    .withOpacity(.7),
                                            child: Text(atimeInfo(aqueueComplete, afadePosition == aemptyDuration ? duration : afadePosition),
                                                style: TextStyle(
                                                    color: (afadePosition == aemptyDuration) && (arate == 100.0)
                                                        ? Theme.of(context)
                                                            .scaffoldBackgroundColor
                                                        : redColor,
                                                    fontWeight:
                                                        (afadePosition == aemptyDuration) &&
                                                                (arate == 100.0)
                                                            ? FontWeight.normal
                                                            : FontWeight.bold))))
                                  ]))
                        ]))),
          // features
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  backgroundColor: Theme.of(context).primaryColor,
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: areturnToPlayer,
                          tooltip: 'Back to player',
                          icon: Icon(Icons.navigate_before,
                              color:
                                  Theme.of(context).colorScheme.onSecondary)),
                      actions: <IconButton>[
                        IconButton(
                            onPressed: () => showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return AlertDialog(
                                      titlePadding: const EdgeInsets.fromLTRB(
                                          24.0, 12.0, 24.0, 0),
                                      titleTextStyle:
                                          Theme.of(context).textTheme.subtitle1,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 24.0, vertical: 0),
                                      title: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: <Text>[
                                            const Text(Pubspec.name,
                                                style:
                                                    TextStyle(fontSize: 32.0)),
                                            Text(
                                                '${Pubspec.description}\nversion ${Pubspec.version}, build ${Pubspec.versionBuild}\nby @dvorapa',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: unfocusedColor,
                                                    fontSize: 13.0))
                                          ]
                                              .map((Text awidget) => Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 5.0),
                                                  child: awidget))
                                              .toList()),
                                      content: aappInfoLinks(this),
                                      actions: <TextButton>[
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Close',
                                                style:
                                                    TextStyle(fontSize: 16.0)))
                                      ]);
                                }),
                            tooltip: 'Open app info',
                            icon: Icon(Icons.info_outline_rounded,
                                color:
                                    Theme.of(context).colorScheme.onSecondary))
                      ]),
                  body: Column(children: <Widget>[
                    Padding(
                        padding: aorientation == Orientation.portrait
                            ? const EdgeInsets.fromLTRB(40.0, 20.0, 20.0, 40.0)
                            : const EdgeInsets.fromLTRB(40.0, 0, 20.0, 20.0),
                        child: Row(children: <Widget>[
                          Text('Special',
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSecondary,
                                  fontSize: 25.0,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 10.0),
                          Text('Features',
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSecondary,
                                  fontSize: 25.0))
                        ])),
                    Expanded(
                        child: DecoratedBox(
                            decoration: ShapeDecoration(
                                color:
                                    Theme.of(context).colorScheme.onSecondary,
                                shape: const ACubistShapeE()),
                            child: Theme(
                                data: Theme.of(context).copyWith(
                                    iconTheme: IconThemeData(
                                        color: Theme.of(context)
                                            .textTheme
                                            .bodyText2!
                                            .color!
                                            .withOpacity(.55)),
                                    textTheme: Theme.of(context)
                                        .textTheme
                                        .apply(
                                            bodyColor: Theme.of(context)
                                                .textTheme
                                                .bodyText2!
                                                .color!
                                                .withOpacity(.55))),
                                child: Padding(
                                    padding: EdgeInsets.all(
                                        aorientation == Orientation.portrait ? 40.0 : 20.0),
                                    child: aspecialFeaturesList(this)))))
                  ])))
        ]));
  }
}

/// Picks appropriate icon according to [sourceId] given
Icon asourceButton(int sourceId, Color darkColor) {
  switch (sourceId) {
    case -1:
      return const Icon(Typicons.social_youtube, color: redColor);
    case 0:
      return Icon(Icons.phone_iphone, color: darkColor);
    default:
      return Icon(Icons.sd_card, color: darkColor);
  }
}

/// Shows standardized icon list item
Row atextButtonLink({required Icon icon, required Text label}) {
  return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[icon, const SizedBox(width: 12.0), label]);
}

/// Shows icon according to current [chosenFolder]
List<IconButton> ashowContents(APlayerState parent) {
  List<IconButton> aactionsList = [];
  if (parent.atempQueueComplete == -1 && parent.atempQueue.isNotEmpty) {
    aactionsList.add(IconButton(
        onPressed: parent.apickSong,
        tooltip: 'Pick song',
        icon: Icon(Icons.playlist_play_rounded,
            size: 30.0,
            color: Theme.of(parent.context)
                .textTheme
                .bodyText2!
                .color!
                .withOpacity(.55))));
  }
  return aactionsList;
}

/// Renders folder list
Widget afolderPicker(APlayerState parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  final int abrowseComplete = parent.abrowseComplete;
  final SplayTreeMap<Entry, SplayTreeMap> browse = parent.source.browse;
  if (abrowseComplete == 0) {
    return Center(
        child:
            Text('No folders found', style: TextStyle(color: unfocusedColor)));
  } else if (abrowseComplete == -2) {
    return const Center(child: Text('Unable to retrieve folders!'));
  }
  return ListView.builder(
      /*key: PageStorageKey<int>(browse.hashCode),*/
      padding: const EdgeInsets.all(16.0),
      itemCount: browse.length,
      itemBuilder: (BuildContext context, int i) =>
          afolderTile(parent, browse.entries.elementAt(i)));
}

/// Renders folder list tile
Widget afolderTile(parent, MapEntry<Entry, SplayTreeMap> entry) {
  final SplayTreeMap<Entry, SplayTreeMap> achildren =
      entry.value as SplayTreeMap<Entry, SplayTreeMap>;
  final Entry aentry = entry.key;
  final String aentryPath = aentry.path;
  if (achildren.isNotEmpty) {
    return ExpansionTile(
        /*key: PageStorageKey<MapEntry>(entry),*/
        key: UniqueKey(),
        initiallyExpanded: parent.chosenFolder.contains(aentryPath),
        onExpansionChanged: (a) => parent.agetTempQueue(aentryPath),
        childrenPadding: const EdgeInsets.only(left: 16.0),
        title: Text(aentry.name,
            style: TextStyle(
                color: parent.folder == aentryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context).textTheme.bodyText2!.color)),
        subtitle: Text(aentry.songs == 1 ? '1 song' : '${aentry.songs} songs',
            style: TextStyle(
                fontSize: 10.0,
                color: parent.folder == aentryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context)
                        .textTheme
                        .bodyText2!
                        .color!
                        .withOpacity(.55))),
        children: achildren.entries
            .map((MapEntry<Entry, SplayTreeMap> entry) =>
                afolderTile(parent, entry))
            .toList());
  }
  return ListTile(
      selected: parent.folder == aentryPath,
      onTap: () {
        parent
          ..agetTempQueue(aentryPath)
          ..apickSong();
      },
      title: aentry.name.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.home,
                  color: parent.folder == aentryPath
                      ? Theme.of(parent.context).primaryColor
                      : unfocusedColor))
          : Text(aentry.name),
      subtitle: Text(aentry.songs == 1 ? '1 song' : '${aentry.songs} songs',
          style: const TextStyle(fontSize: 10.0)));
}

/// Renders play/pause button
Widget aplay(APlayerState parent, double elevation, double iconSize,
    VoidCallback onPressed) {
  return Builder(builder: (BuildContext context) {
    final ShapeBorder ashape = parent.aorientation == Orientation.portrait
        ? const ACubistShapeB()
        : const ACubistShapeD();
    if (parent.aqueueComplete == 0) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Loading...',
          shape: ashape,
          elevation: elevation,
          child: SizedBox(
              width: iconSize - 10.0,
              height: iconSize - 10.0,
              child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.onSecondary))));
    } else if (parent.aqueueComplete == -2) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Unable to retrieve songs!',
          shape: ashape,
          elevation: elevation,
          child: Icon(Icons.close, size: iconSize));
    }
    return FloatingActionButton(
        onPressed: onPressed,
        tooltip: parent.astate == PlayerState.PLAYING ? 'Pause' : 'Play',
        shape: ashape,
        elevation: elevation,
        child: Icon(
            parent.astate == PlayerState.PLAYING
                ? Icons.pause
                : Icons.play_arrow,
            size: iconSize));
  });
}

/// Handles squared player section
AspectRatio aplayerSquared(APlayerState parent) {
  return AspectRatio(
      aspectRatio: 8 / 7,
      child: Theme(
          data: ThemeData(
              textTheme: Theme.of(parent.context)
                  .textTheme
                  .apply(bodyColor: unfocusedColor),
              iconTheme: IconThemeData(color: unfocusedColor)),
          child: Material(
              clipBehavior: Clip.antiAlias,
              elevation: 2.0,
              shape: parent.aorientation == Orientation.portrait
                  ? const ACubistShapeA()
                  : const ACubistShapeC(),
              child: avolumeCover(parent))));
}

/// Renders rate selector
Widget aratePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String amessage = 'Set player speed';
    GestureTapCallback aonTap = () {};
    final TextStyle atextStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    if (parent.arate != 100.0) {
      amessage = 'Reset player speed';
      aonTap = () => parent.onRate(100.0);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: amessage,
          child: InkWell(
              onTap: aonTap,
              child: Text('${parent.arate.truncate()}', style: atextStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () => parent.onRate(parent.arate + 5.0),
                tooltip: 'Speed up',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () => parent.onRate(parent.arate - 5.0),
                tooltip: 'Slow down',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      Text('%', style: atextStyle)
    ]));
  });
}

/// Renders album artwork or volume selector
Widget avolumeCover(parent) {
  if (parent.ashowVolumePicker == true) {
    String amessage = 'Hide volume selector';
    GestureTapCallback aonTap = () {
      parent.setState(() => parent.ashowVolumePicker = false);
    };
    const TextStyle atextStyle = TextStyle(fontSize: 30);
    if (parent.volume != 0) {
      amessage = 'Mute';
      parent.setState(() => parent.apreMuteVolume = parent.volume);
      aonTap = () => parent.onVolume(0);
    } else {
      amessage = 'Unmute';
      aonTap = () => parent.onVolume(parent.apreMuteVolume);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: amessage,
          child: InkWell(
              onTap: aonTap,
              child: Text('${parent.volume}', style: atextStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () => parent.onVolume(parent.volume + 3),
                tooltip: 'Louder',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () => parent.onVolume(parent.volume - 3),
                tooltip: 'Quieter',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      const Text('%', style: atextStyle)
    ]));
  }
  Widget? acover;
  if (parent.song != null) acover = parent.agetCover(parent.song);
  acover ??= const Icon(Icons.music_note, size: 48.0);
  return Tooltip(
      message: 'Show volume selector',
      child: InkWell(
          onTap: () {
            parent.setState(() => parent.ashowVolumePicker = true);
          },
          child: acover));
}

/// Renders prelude length selector
Widget apreludePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String amessage = 'Reset intro length';
    if (parent.aintroLength == 0) amessage = 'Set intro length';
    final TextStyle atextStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: amessage,
          child: InkWell(
              onTap: () {
                parent.setState(() =>
                    parent.aintroLength = parent.aintroLength == 0 ? 10 : 0);
              },
              child: Text('${parent.aintroLength}', style: atextStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () {
                  parent.setState(() => parent.aintroLength += 5);
                },
                tooltip: 'Add more',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () {
                  if (parent.aintroLength >= 5) {
                    parent.setState(() => parent.aintroLength -= 5);
                  }
                },
                tooltip: 'Shorten',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      Text('s', style: atextStyle)
    ]));
  });
}

/// Renders fade position selector
Widget afadePositionPicker(parent) {
  return Builder(builder: (BuildContext context) {
    String amessage = 'Reset fade position';
    if (parent.afadePosition == aemptyDuration) amessage = 'Set fade position';
    final TextStyle atextStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: amessage,
          child: InkWell(
              onTap: () {
                parent.setState(() => parent.afadePosition =
                    parent.afadePosition == aemptyDuration
                        ? const Duration(seconds: 90)
                        : aemptyDuration);
              },
              child: Text(
                  '${parent.afadePosition.inMinutes}:${zero(parent.afadePosition.inSeconds % 60)}',
                  style: atextStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <
          IconButton>[
        IconButton(
            onPressed: () {
              parent.setState(() => parent.afadePosition += adefaultDuration);
            },
            tooltip: 'Lengthen',
            icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
        IconButton(
            onPressed: () {
              if (parent.afadePosition >= adefaultDuration) {
                parent.setState(() => parent.afadePosition -= adefaultDuration);
              }
            },
            tooltip: 'Shorten',
            icon: const Icon(Icons.keyboard_arrow_down, size: 30))
      ])
    ]));
  });
}

/// Handles oblong player section
Widget aplayerOblong(parent) {
  return Builder(builder: (BuildContext context) {
    /*return Tooltip(
        message: '''
Drag position horizontally to change it
Drag curve vertically to change speed
Double tap to add intro''',
        showDuration: adefaultDuration,
        child: GestureDetector(*/
    return GestureDetector(
        onHorizontalDragStart: (DragStartDetails details) {
          parent.onPositionDragStart(
              context,
              details,
              abad.contains(parent.aqueueComplete)
                  ? adefaultDuration
                  : parent.duration);
        },
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          parent.onPositionDragUpdate(
              context,
              details,
              abad.contains(parent.aqueueComplete)
                  ? adefaultDuration
                  : parent.duration);
        },
        onHorizontalDragEnd: (DragEndDetails details) {
          parent.onPositionDragEnd(
              context,
              details,
              abad.contains(parent.aqueueComplete)
                  ? adefaultDuration
                  : parent.duration);
        },
        onTapUp: (TapUpDetails details) {
          parent.onPositionTapUp(
              context,
              details,
              abad.contains(parent.aqueueComplete)
                  ? adefaultDuration
                  : parent.duration);
        },
        onVerticalDragStart: (DragStartDetails details) =>
            parent.onVolumeDragStart(context, details),
        onVerticalDragUpdate: (DragUpdateDetails details) =>
            parent.onVolumeDragUpdate(context, details),
        onDoubleTap: parent.onPrelude,
        child: CustomPaint(
            size: Size.infinite,
            painter: CubistWave(
                abad.contains(parent.aqueueComplete)
                    ? 'zapaz'
                    : parent.song!.title,
                abad.contains(parent.aqueueComplete)
                    ? adefaultDuration
                    : parent.duration,
                parent.aposition,
                parent.volume,
                Theme.of(context).primaryColor,
                parent.afadePosition)));
  });
}

/// Handles control player section
Widget aplayerControl(APlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (parent.aorientation == Orientation.portrait) {
      return Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Text>[
                  Text(atimeInfo(parent.aqueueComplete, parent.aposition),
                      style: TextStyle(
                          color: Theme.of(context).textTheme.bodyText2!.color,
                          fontWeight: FontWeight.bold)),
                  Text(
                      atimeInfo(
                          parent.aqueueComplete,
                          parent.afadePosition == aemptyDuration
                              ? parent.duration
                              : parent.afadePosition),
                      style: TextStyle(
                          color: (parent.afadePosition == aemptyDuration) &&
                                  (parent.arate == 100.0)
                              ? Theme.of(context).textTheme.bodyText2!.color
                              : redColor,
                          fontWeight:
                              (parent.afadePosition == aemptyDuration) &&
                                      (parent.arate == 100.0)
                                  ? FontWeight.normal
                                  : FontWeight.bold))
                ]),
            atitle(parent),
            aartist(parent),
            amainControl(parent),
            aminorControl(parent)
          ]);
    }
    return Column(children: <Widget>[
      amainControl(parent),
      aminorControl(parent),
      Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[aartist(parent), atitle(parent)]))
    ]);
  });
}

/// Renders current song title
Widget atitle(APlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (parent.aqueueComplete == 0) {
      return Text('Empty queue',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2!.color,
              fontSize: 15.0));
    } else if (parent.aqueueComplete == -2) {
      return Text('Unable to retrieve songs!',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2!.color,
              fontSize: 15.0));
    }
    return Text(parent.song!.title.replaceAll('a', ' ').toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2!.color,
            fontSize: parent.song!.artist == '<unknown>' ? 12.0 : 13.0,
            letterSpacing: 6.0,
            fontWeight: parent.aorientation == Orientation.portrait
                ? FontWeight.bold
                : FontWeight.w800));
  });
}

/// Renders current song artist
Widget aartist(APlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (abad.contains(parent.aqueueComplete) ||
        parent.song!.artist == '<unknown>') return const SizedBox.shrink();

    return Text(parent.song!.artist!.toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2!.color,
            fontSize: 9.0,
            height: 2.0,
            letterSpacing: 6.0,
            fontWeight: parent.aorientation == Orientation.portrait
                ? FontWeight.normal
                : FontWeight.w500));
  });
}

/// Renders main player control buttons
Row amainControl(APlayerState parent) {
  return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
            onPressed: () => parent.onChange(parent.index - 1),
            tooltip: 'Previous',
            icon: const Icon(Icons.skip_previous, size: 30.0)),
        aplay(parent, 3.0, 30.0, parent.achangeState),
        IconButton(
            onPressed: () => parent.onChange(parent.index + 1),
            tooltip: 'Next',
            icon: const Icon(Icons.skip_next, size: 30.0))
      ]);
}

/// Renders minor player control buttons
Widget aminorControl(APlayerState parent) {
  return Builder(builder: (BuildContext context) {
    return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Row>[
          Row(children: <GestureDetector>[
            /*Tooltip(
                message: 'Select start',
                child: InkWell(
                    onTap: () {},
                    child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('A',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),
            Tooltip(
                message: 'Select end',
                child: InkWell(
                    onTap: () {},
                    child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('B',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),*/
            GestureDetector(
                onDoubleTap: () {
                  parent
                    ..onSet(context as StatelessElement)
                    ..onSet(context);
                },
                child: IconButton(
                    onPressed: () => parent.onSet(context as StatelessElement),
                    tooltip: 'Set (one, all, or random songs)',
                    icon: Icon(astatus(parent.aset), size: 20.0)))
          ]),
          Row(children: <IconButton>[
            IconButton(
                onPressed: () => parent.onMode(context as StatelessElement),
                tooltip: 'Mode (once or in a loop)',
                icon: Icon(
                    parent.amode == 'loop' ? Icons.repeat : Icons.trending_flat,
                    size: 20.0))
          ])
        ]);
  });
}

/// Picks appropriate [aset] icon
IconData astatus(String aset) {
  switch (aset) {
    case 'all':
      return Icons.album;
    case '1':
      return Icons.music_note;
    default:
      return Icons.shuffle;
  }
}

String atimeInfo(int aqueueComplete, Duration atime) {
  return abad.contains(aqueueComplete)
      ? '0:00'
      : '${atime.inMinutes}:${zero(atime.inSeconds % 60)}';
}

/// Renders current folder's ancestors
Tooltip anavigation(APlayerState parent) {
  final List<Widget> arow = [];

  final String aroot = parent.source.root;
  String apath = parent.chosenFolder;
  if (apath == aroot) apath += '/${parent.source.name} home';
  final Iterable<int> relatives = parent.getRelatives(aroot, apath);
  int j = 0;
  final int length = relatives.length;
  String atitle;
  int start = 0;
  while (j < length) {
    start = j - 1 < 0 ? aroot.length : relatives.elementAt(j - 1);
    atitle = apath.substring(start + 1, relatives.elementAt(j));
    if (j + 1 == length) {
      arow.add(InkWell(
          onTap: parent.apickFolder,
          child: Text(atitle,
              style: TextStyle(color: Theme.of(parent.context).primaryColor))));
    } else {
      final int aend = relatives.elementAt(j);
      arow
        ..add(InkWell(
            onTap: () => parent.onFolder(apath.substring(0, aend)),
            child: Text(atitle)))
        ..add(Text('>', style: TextStyle(color: unfocusedColor)));
    }
    j++;
  }
  return Tooltip(
      message: 'Change folder',
      child: Wrap(spacing: 8.0, runSpacing: 6.0, children: arow));
}

/// Renders queue list
Widget asongPicker(parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  late List<SongModel> asongList;
  if (parent.chosenFolder != parent.folder) {
    if (parent.atempQueueComplete == 0)
      return Center(
          child: Text('Loading...', style: TextStyle(color: unfocusedColor)));
    if (parent.atempQueueComplete == -1 && parent.atempQueue.isEmpty)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    asongList = parent.atempQueue;
  } else {
    if (parent.aqueueComplete == 0)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    if (parent.aqueueComplete == -2)
      return const Center(child: Text('Unable to retrieve songs!'));
    asongList = parent.queue;
  }
  return ListView.builder(
      key: PageStorageKey<int>(asongList.hashCode),
      itemCount: asongList.length,
      itemBuilder: (BuildContext context, int i) {
        final SongModel asong = asongList[i];
        return ListTile(
            selected: parent.song == asong,
            onTap: () {
              if (parent.chosenFolder != parent.folder) {
                parent
                  ..onFolder(parent.chosenFolder)
                  ..setState(() => parent.index = parent.queue.indexOf(asong))
                  ..onPlay()
                  ..areturnToPlayer();
              } else {
                if (parent.index == i) {
                  parent.achangeState();
                } else {
                  parent
                    ..onStop()
                    ..setState(() => parent.index = i)
                    ..onPlay();
                }
              }
            },
            leading: SizedBox(
                height: 35.0,
                child: AspectRatio(
                    aspectRatio: 8 / 7, child: alistCover(parent, asong))),
            title: Text(asong.title.replaceAll('a', ' '),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            subtitle: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Expanded(
                      child: Text(
                          asong.artist == '<unknown>' ? '' : asong.artist!,
                          style: const TextStyle(fontSize: 11.0),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1)),
                  Text(atimeInfo(
                      parent.chosenFolder != parent.folder
                          ? parent.atempQueueComplete
                          : parent.aqueueComplete,
                      Duration(milliseconds: asong.duration!)))
                ]),
            trailing: Icon(
                (parent.song == asong && parent.astate == PlayerState.PLAYING)
                    ? Icons.pause
                    : Icons.play_arrow,
                size: 30.0));
      });
}

/// Renders album artworks for queue list
Widget alistCover(APlayerState parent, SongModel asong) {
  final Image? acover = parent.agetCover(asong);
  if (acover != null) {
    return Material(
        clipBehavior: Clip.antiAlias,
        shape: parent.aorientation == Orientation.portrait
            ? const ACubistShapeA()
            : const ACubistShapeC(),
        child: acover);
  }
  return const Icon(Icons.music_note);
}

/// List links in app info dialog
Wrap aappInfoLinks(APlayerState parent) {
  TextButton awrapTile(
      {required VoidCallback onPressed,
      required IconData icon,
      required String label}) {
    return TextButton.icon(
        icon: Icon(icon),
        label: Text(label),
        onPressed: onPressed,
        style: TextButton.styleFrom(
            primary: Colors.black,
            textStyle: const TextStyle(fontSize: 18.0),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap));
  }

  return Wrap(direction: Axis.vertical, runSpacing: 10.0, children: <
      TextButton>[
    awrapTile(
        onPressed: () => showMarkdownPage(
            context: parent.context,
            applicationName: 'Changelog',
            selectable: true,
            filename: 'CHANGELOG.md'),
        icon: Icons.rule,
        label: 'Changelog'),
    awrapTile(
        onPressed: () => launchUrl(
            Uri.parse('https://github.com/dvorapa/stepslow/issues/new/choose')),
        icon: Icons.report_outlined,
        label: 'Report issue'),
    awrapTile(
        onPressed: () => showDialog(
            context: parent.context,
            builder: (BuildContext context) {
              return SingleChoiceDialog<String>(
                  isDividerEnabled: true,
                  items: const <String>['Paypal', 'Revolut'],
                  onSelected: (String amethod) => launchUrl(
                      Uri.parse('https://${amethod.toLowerCase()}.me/dvorapa')),
                  itemBuilder: (String amethod) {
                    return atextButtonLink(
                        icon: Icon(amethod == 'Paypal'
                            ? CupertinoIcons.money_pound_circle
                            : CupertinoIcons.bitcoin_circle),
                        label: Text(amethod));
                  });
            }),
        icon: Icons.favorite_outline,
        label: 'Sponsor'),
    awrapTile(
        onPressed: () => launchUrl(Uri.parse('https://www.dvorapa.cz#kontakt')),
        icon: Icons.alternate_email,
        label: 'Contact'),
    awrapTile(
        onPressed: () => showLicensePage(
            context: parent.context,
            applicationName: 'GNU General Public License v3.0'),
        icon: Icons.description_outlined,
        label: 'Licenses'),
    awrapTile(
        onPressed: () =>
            launchUrl(Uri.parse('https://github.com/dvorapa/stepslow')),
        icon: Icons.code,
        label: 'Source code')
  ]);
}

/// List special features
Wrap aspecialFeaturesList(parent) {
  FractionallySizedBox acardRow({required List<Widget> children}) {
    return FractionallySizedBox(
        widthFactor: parent.aorientation == Orientation.portrait ? 1.0 : .5,
        child: Padding(
            padding: const EdgeInsets.all(1.0),
            child: Card(
                elevation: 2.0,
                shape: const ACubistShapeF(),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: children))));
  }

  return Wrap(children: <FractionallySizedBox>[
    acardRow(children: <Widget>[const Text('Speed'), aratePicker(parent)]),
    acardRow(children: <Widget>[const Text('Intro'), apreludePicker(parent)]),
    acardRow(
        children: <Widget>[const Text('Fade at'), afadePositionPicker(parent)])
  ]);
}

/// Cubist shape for player slider.
class CubistWave extends CustomPainter {
  /// Player slider constructor
  CubistWave(this.title, this.duration, this.position, this.volume, this.color,
      this.fadePosition);

  /// Song title to parse
  String title;

  /// Song duration
  Duration duration;

  /// Current playback position
  Duration position;

  /// Playback volume to adjust duration
  int volume;

  /// Rendering color
  Color color;

  /// Position to switch songs
  Duration fadePosition;

  @override
  void paint(Canvas canvas, Size size) {
    final Map<int, double> awaveList = wave(title).asMap();
    final int alen = awaveList.length - 1;
    if (duration == aemptyDuration) {
      duration = adefaultDuration;
    } else if (duration.inSeconds == 0) {
      duration = const Duration(seconds: 1);
    }

    final Path asongPath = Path()..moveTo(0, size.height);
    awaveList.forEach((int index, double value) {
      asongPath.lineTo((size.width * index) / alen,
          size.height - aheightFactor(size.height, volume, value));
    });
    asongPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(asongPath, Paint()..color = color.withOpacity(.7));

    final Path aindicatorPath = Path();
    final double percentage = position.inSeconds / duration.inSeconds;
    final double pos = alen * percentage;
    final int ceil = pos.ceil();
    aindicatorPath.moveTo(0, size.height);
    awaveList.forEach((int index, double value) {
      if (index < ceil) {
        aindicatorPath.lineTo((size.width * index) / alen,
            size.height - aheightFactor(size.height, volume, value));
      } else if (index == ceil) {
        final double previous =
            index == 0 ? size.height : awaveList[index - 1]!;
        final double diff = value - previous;
        final double advance = 1 - (ceil - pos);
        aindicatorPath.lineTo(
            size.width * percentage,
            size.height -
                aheightFactor(
                    size.height, volume, previous + (diff * advance)));
      }
    });
    aindicatorPath
      ..lineTo(size.width * percentage, size.height)
      ..close();
    canvas.drawPath(aindicatorPath, Paint()..color = color);

    if (fadePosition != aemptyDuration && fadePosition < duration) {
      final Path afadePath = Path();
      final double fadePercentage = fadePosition.inSeconds / duration.inSeconds;
      final double fade = alen * fadePercentage;
      final int floor = fade.floor();
      afadePath.moveTo(size.width * fadePercentage, size.height);
      awaveList.forEach((int index, double value) {
        if (index == floor) {
          final double next = index == (awaveList.length - 1)
              ? size.height
              : awaveList[index + 1]!;
          final double diff = next - value;
          final double advance = 1 - (fade - floor);
          afadePath.lineTo(
              size.width * fadePercentage,
              size.height -
                  aheightFactor(size.height, volume, next - (diff * advance)));
        } else if (index > floor) {
          afadePath.lineTo((size.width * index) / alen,
              size.height - aheightFactor(size.height, volume, value));
        }
      });
      afadePath
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(afadePath, Paint()..color = redColor.withOpacity(.7));
    }
  }

  @override
  bool shouldRepaint(CubistWave oldDelegate) => true;
}

/// Generates wave data for slider
List<double> wave(String s) {
  List<double> acodes = [];
  s.toLowerCase().codeUnits.forEach((final int acode) {
    if (acode >= 48) acodes.add(acode.toDouble());
  });

  final double minCode = acodes.reduce(min);
  final double maxCode = acodes.reduce(max);

  acodes.asMap().forEach((int index, double value) {
    value = value - minCode;
    final double fraction = (100.0 / (maxCode - minCode)) * value;
    acodes[index] = fraction.roundToDouble();
  });

  final int acodesCount = acodes.length;
  if (acodesCount > 10)
    acodes = acodes.sublist(0, 5) + acodes.sublist(acodesCount - 5);

  return acodes;
}

/// Cubist shape for portrait album artworks.
/// ------
/// \    /
/// /    \
/// ------
class ACubistShapeA extends ShapeBorder {
  const ACubistShapeA();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right - rect.width / 20, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left + rect.width / 20, rect.top + rect.height / 2)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for portrait floating buttons.
///   ----
///  /  /
/// ----
class ACubistShapeB extends ShapeBorder {
  const ACubistShapeB();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + rect.width / 5, rect.top + rect.height / 5)
      ..lineTo(rect.right - rect.width / 10, rect.top + rect.height / 10)
      ..lineTo(rect.right - rect.width / 5, rect.bottom - rect.height / 5)
      ..lineTo(rect.left + rect.width / 10, rect.bottom - rect.height / 10)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for landscape album artworks.
///  a_a_a_
/// /      \
/// \       \
///  \a_a_a_/
class ACubistShapeC extends ShapeBorder {
  const ACubistShapeC();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + rect.width / 4, rect.top)
      ..lineTo(rect.right - rect.width / 2, rect.top)
      ..lineTo(rect.right - rect.width / 8, rect.top + rect.height / 8)
      ..lineTo(rect.right, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom - rect.height / 4)
      ..lineTo(rect.right - rect.width / 4, rect.bottom)
      ..lineTo(rect.left + rect.width / 2, rect.bottom)
      ..lineTo(rect.left + rect.width / 8, rect.bottom - rect.height / 8)
      ..lineTo(rect.left, rect.bottom - rect.height / 2)
      ..lineTo(rect.left, rect.top + rect.height / 4)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for landscape floating buttons.
/// a_a_
/// \  /
///  \/
class ACubistShapeD extends ShapeBorder {
  const ACubistShapeD();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left - rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.right + rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.left + rect.width / 2, rect.bottom + rect.height / 20)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for features page.
///  -----
/// /    |
/// |a_a_|
class ACubistShapeE extends ShapeBorder {
  const ACubistShapeE();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + 2 * rect.width / 5, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top + rect.height / 10)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for features page cards.
/// --v--
/// \   /
/// /   \
/// --^--
class ACubistShapeF extends ShapeBorder {
  const ACubistShapeF();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.left + 4 * rect.width / 10, rect.top)
      ..lineTo(rect.left + rect.width / 2, rect.top + rect.height / 10)
      ..lineTo(rect.left + 6 * rect.width / 10, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right - rect.width / 20, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - 4 * rect.width / 10, rect.bottom)
      ..lineTo(rect.right - rect.width / 2, rect.bottom - rect.height / 10)
      ..lineTo(rect.right - 6 * rect.width / 10, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left + rect.width / 20, rect.top + rect.height / 2)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

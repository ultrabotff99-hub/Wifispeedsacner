import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(WifiScannerApp(prefs: prefs));
}

class WifiScannerApp extends StatefulWidget {
  final SharedPreferences prefs;
  const WifiScannerApp({super.key, required this.prefs});
  @override
  State<WifiScannerApp> createState() => _WifiScannerAppState();
}

class _WifiScannerAppState extends State<WifiScannerApp> {
  late bool _dark;
  @override
  void initState() {
    super.initState();
    _dark = widget.prefs.getBool('dark') ?? false;
  }
  void _toggleTheme() {
    setState(() => _dark = !_dark);
    widget.prefs.setBool('dark', _dark);
  }
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WiFi Scanner Pro',
      debugShowCheckedModeBanner: false,
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark),
      home: HomePage(prefs: widget.prefs, onToggleTheme: _toggleTheme),
    );
  }
}

class WifiNetwork {
  final String ssid, bssid, capabilities;
  final int rssi, frequency, channel;
  final DateTime seenAt;
  final double direction;

  WifiNetwork({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.channel,
    required this.capabilities,
    required this.seenAt,
    required this.direction,
  });

  factory WifiNetwork.fromMap(Map<String, dynamic> m) {
    final bssid = (m['bssid'] ?? '').toString();
    return WifiNetwork(
      ssid: (m['ssid'] ?? '').toString(),
      bssid: bssid,
      rssi: (m['rssi'] ?? -100) as int,
      frequency: (m['frequency'] ?? 0) as int,
      channel: (m['channel'] ?? 0) as int,
      capabilities: (m['capabilities'] ?? '').toString(),
      seenAt: DateTime.now(),
      direction: _dirFromBssid(bssid),
    );
  }

  static double _dirFromBssid(String b) {
    var h = 0;
    for (final c in b.codeUnits) h = (h * 31 + c) & 0x7fffffff;
    return (h % 360) * pi / 180;
  }

  String get security {
    final c = capabilities.toUpperCase();
    if (c.contains('WPA3') || c.contains('SAE')) return 'WPA3';
    if (c.contains('WPA2') || c.contains('RSN')) return 'WPA2';
    if (c.contains('WPA')) return 'WPA';
    if (c.contains('WEP')) return 'WEP';
    return 'Open';
  }

  String get band => frequency >= 5925
      ? '6 GHz'
      : frequency >= 4900 ? '5 GHz' : '2.4 GHz';

  int get signalPercent => ((rssi + 100) * 100 / 60).clamp(0, 100).round();
  bool get isOpen => security == 'Open';
  bool get isHidden => ssid.isEmpty;
  bool get isWps => capabilities.toUpperCase().contains('WPS');

  int get estimatedSpeed {
    final c = capabilities.toUpperCase();
    if (c.contains('AX') || c.contains('HE')) return 1200;
    if (c.contains('AC') || c.contains('VHT')) return 866;
    if (c.contains('N') || c.contains('HT')) return 300;
    if (c.contains('G')) return 54;
    return 11;
  }

  int get riskScore {
    int s = 0;
    if (isOpen) s += 60;
    if (security == 'WEP') s += 50;
    if (security == 'WPA') s += 30;
    if (isWps) s += 15;
    if (isHidden) s += 10;
    if (signalPercent > 80) s += 5;
    return s.clamp(0, 100);
  }

  Color get borderColor {
    if (riskScore >= 50) return Colors.red;
    switch (security) {
      case 'WPA3':
        return Colors.green;
      case 'WPA2':
        return Colors.orange;
      case 'WPA':
        return Colors.blue;
      case 'WEP':
        return Colors.purple;
      default:
        return Colors.red;
    }
  }

  Map<String, dynamic> toJson() => {
        'ssid': ssid,
        'bssid': bssid,
        'rssi': rssi,
        'frequency': frequency,
        'channel': channel,
        'capabilities': capabilities,
        'security': security,
        'band': band,
        'signalPercent': signalPercent,
        'estimatedSpeedMbps': estimatedSpeed,
        'riskScore': riskScore,
        'seenAt': seenAt.toIso8601String(),
      };
}

class Analyzer {
  static Map<int, int> channelCongestion(List<WifiNetwork> nets) {
    final m = <int, int>{};
    for (final n in nets) m[n.channel] = (m[n.channel] ?? 0) + 1;
    return m;
  }

  static int recommendChannel(Map<int, int> congestion) {
    const candidates = [1, 6, 11];
    candidates.sort(
        (a, b) => (congestion[a] ?? 0).compareTo(congestion[b] ?? 0));
    return candidates.first;
  }

  static List<MapEntry<String, List<WifiNetwork>>> rogueGroups(
      List<WifiNetwork> nets) {
    final bySsid = <String, List<WifiNetwork>>{};
    for (final n in nets) {
      if (n.ssid.isEmpty) continue;
      bySsid.putIfAbsent(n.ssid, () => []).add(n);
    }
    return bySsid.entries
        .where((e) => e.value.map((n) => n.bssid).toSet().length > 1)
        .toList();
  }

  static int trend(List<int> h) {
    if (h.length < 3) return 0;
    final d = h.last - h[h.length - 3];
    return d > 4 ? 1 : (d < -4 ? -1 : 0);
  }
}

enum SortBy { signalDesc, signalAsc, ssid, riskDesc, security }

class HomePage extends StatefulWidget {
  final SharedPreferences prefs;
  final VoidCallback onToggleTheme;
  const HomePage({super.key, required this.prefs, required this.onToggleTheme});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _ch = MethodChannel('wifi_scan');
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchCtrl = TextEditingController();

  List<WifiNetwork> networks = [];
  final Map<String, List<int>> history = {};
  Set<String> favorites = {};
  List<MapEntry<String, List<WifiNetwork>>> rogueGroups = [];

  bool scanning = false;
  String? error;
  String bandFilter = 'All';
  SortBy sortBy = SortBy.signalDesc;
  bool onlyFavorites = false;
  bool showSearch = false;
  bool autoRefresh = true;
  int refreshSec = 10;
  Timer? _timer;

  List<WifiNetwork> get filtered {
    var list = networks.where((n) {
      if (bandFilter != 'All' && n.band != bandFilter) return false;
      if (onlyFavorites && !favorites.contains(n.bssid)) return false;
      final q = _searchCtrl.text.trim().toLowerCase();
      if (q.isNotEmpty && !n.ssid.toLowerCase().contains(q)) return false;
      return true;
    }).toList();

    switch (sortBy) {
      case SortBy.signalDesc:
        list.sort((a, b) => b.rssi.compareTo(a.rssi));
        break;
      case SortBy.signalAsc:
        list.sort((a, b) => a.rssi.compareTo(b.rssi));
        break;
      case SortBy.ssid:
        list.sort((a, b) =>
            a.ssid.toLowerCase().compareTo(b.ssid.toLowerCase()));
        break;
      case SortBy.riskDesc:
        list.sort((a, b) => b.riskScore.compareTo(a.riskScore));
        break;
      case SortBy.security:
        list.sort((a, b) => a.security.compareTo(b.security));
        break;
    }
    return list;
  }

  int get _openCount => networks.where((n) => n.isOpen).length;
  int get _wpa3Count => networks.where((n) => n.security == 'WPA3').length;
  int get _highRiskCount => networks.where((n) => n.riskScore >= 50).length;

  @override
  void initState() {
    super.initState();
    favorites = (widget.prefs.getStringList('favs') ?? []).toSet();
    refreshSec = widget.prefs.getInt('refreshSec') ?? 10;
    _searchCtrl.addListener(() => setState(() {}));
    _init();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final loc = await Permission.location.request();
    if (!loc.isGranted) {
      setState(() => error = 'Location permission അനിവാര്യമാണ്');
      return;
    }
    await _scan();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: refreshSec), (_) {
      if (autoRefresh && !scanning) _scan();
    });
  }

  Future<void> _scan() async {
    if (scanning) return;
    setState(() {
      scanning = true;
      error = null;
    });
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('startScan');
      final list = (raw ?? [])
          .map((e) => WifiNetwork.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted) return;
      setState(() {
        networks = list;
        for (final n in list) {
          final h = history.putIfAbsent(n.bssid, () => []);
          h.add(n.rssi);
          if (h.length > 20) h.removeAt(0);
        }
        rogueGroups = Analyzer.rogueGroups(list);
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Scan failed');
    } on MissingPluginException {
      if (mounted) setState(() => error = 'Native plugin load ചെയ്തില്ല');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  void _toggleFav(WifiNetwork n) {
    setState(() {
      favorites.contains(n.bssid)
          ? favorites.remove(n.bssid)
          : favorites.add(n.bssid);
    });
    widget.prefs.setStringList('favs', favorites.toList());
  }

  Future<void> _export(String type) async {
    final data = filtered;
    if (data.isEmpty) return;
    String body;
    if (type == 'json') {
      body = const JsonEncoder.withIndent('  ')
          .convert(data.map((e) => e.toJson()).toList());
    } else {
      final buf = StringBuffer(
          'SSID,BSSID,Security,Band,Channel,RSSI,Signal%,Risk,Speed\n');
      for (final n in data) {
        buf.writeln(
            '"${n.ssid}","${n.bssid}",${n.security},${n.band},${n.channel},'
            '${n.rssi},${n.signalPercent},${n.riskScore},${n.estimatedSpeed}');
      }
      body = buf.toString();
    }
    await Share.share(body,
        subject:
            'WiFi Scan ${type.toUpperCase()} (${data.length} networks)');
  }

  Future<void> _syncEsp32(String ip) async {
    final url = Uri.parse('http://$ip/scan');
    final resp = await http.get(url).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final data = jsonDecode(resp.body) as List;
    final list = data
        .map((m) => WifiNetwork.fromMap(Map<String, dynamic>.from(m)))
        .toList();
    if (!mounted) return;
    setState(() {
      networks = list;
      for (final n in list) {
        final h = history.putIfAbsent(n.bssid, () => []);
        h.add(n.rssi);
        if (h.length > 20) h.removeAt(0);
      }
      rogueGroups = Analyzer.rogueGroups(list);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WiFi Scanner Pro',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text('${networks.length} networks',
                style: const TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(showSearch ? Icons.search_off : Icons.search),
            onPressed: () {
              setState(() {
                showSearch = !showSearch;
                if (!showSearch) _searchCtrl.clear();
              });
            },
          ),
          IconButton(
            onPressed: scanning ? null : _scan,
            icon: scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
        bottom: showSearch
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'SSID തിരയുക...',
                      filled: true,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => _searchCtrl.clear())
                          : null,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              )
            : null,
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          SizedBox(height: 200, child: ScanBubbles(networks: filtered)),
          _buildStatsRow(),
          SizedBox(height: 110, child: ChannelChart(networks: networks)),
          _buildFilterRow(),
          if (error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Colors.red.withOpacity(0.1),
              child: Text(error!,
                  style: const TextStyle(
                      color: Colors.red, fontSize: 12)),
            ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                        networks.isEmpty
                            ? 'സ്കാൻ ചെയ്യുന്നു...'
                            : 'ഫിൽട്ടറുമായി ഒത്തുപോകുന്ന നെറ്റ്‌വർക്കുകളില്ല',
                        style:
                            const TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => _buildTile(filtered[i]),
                  ),
          ),
        ],
      ),
      floatingActionButton: scanning
          ? null
          : FloatingActionButton.extended(
              onPressed: _scan,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Scan'),
            ),
    );
  }

  Widget _buildStatsRow() {
    Widget card(String label, String value, Color c) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: c.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.withOpacity(0.4)),
            ),
            child: Column(
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: c)),
                Text(label, style: const TextStyle(fontSize: 10)),
              ],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          card('Total', '${networks.length}', Colors.blue),
          card('Open', '$_openCount', Colors.red),
          card('WPA3', '$_wpa3Count', Colors.green),
          card('Risk', '$_highRiskCount', Colors.deepOrange),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final b in ['All', '2.4 GHz', '5 GHz', '6 GHz'])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(b),
                selected: bandFilter == b,
                onSelected: (_) => setState(() => bandFilter = b),
              ),
            ),
          const SizedBox(width: 4),
          FilterChip(
            avatar:
                Icon(onlyFavorites ? Icons.star : Icons.star_border, size: 16),
            label: const Text('Favorites'),
            selected: onlyFavorites,
            onSelected: (v) => setState(() => onlyFavorites = v),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<SortBy>(
            icon: const Icon(Icons.sort),
            onSelected: (v) => setState(() => sortBy = v),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: SortBy.signalDesc, child: Text('Signal ↓')),
              PopupMenuItem(
                  value: SortBy.signalAsc, child: Text('Signal ↑')),
              PopupMenuItem(value: SortBy.ssid, child: Text('SSID')),
              PopupMenuItem(
                  value: SortBy.riskDesc, child: Text('Risk')),
              PopupMenuItem(
                  value: SortBy.security, child: Text('Security')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTile(WifiNetwork n) {
    final trend = Analyzer.trend(history[n.bssid] ?? []);
    final isFav = favorites.contains(n.bssid);
    final trendIcon = trend > 0
        ? Icons.trending_up
        : trend < 0
            ? Icons.trending_down
            : Icons.trending_flat;
    final trendColor = trend > 0
        ? Colors.green
        : trend < 0
            ? Colors.red
            : Colors.grey;

    return GestureDetector(
      onTap: () => _showDetails(n),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: n.borderColor, width: 2),
          borderRadius: BorderRadius.circular(12),
          color: n.borderColor.withOpacity(0.06),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi, color: n.borderColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          n.isHidden ? '(Hidden)' : n.ssid,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (n.isWps) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.warning_amber,
                            size: 14, color: Colors.amber),
                      ],
                      if (n.riskScore >= 50) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.dangerous,
                            size: 14, color: Colors.red),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${n.security} • ${n.band} • Ch ${n.channel} • '
                    '${n.signalPercent}% • ~${n.estimatedSpeed} Mbps',
                    style: const TextStyle(
                        fontSize: 11, c

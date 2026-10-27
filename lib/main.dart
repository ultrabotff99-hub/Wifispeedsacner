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
                        fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(trendIcon, size: 16, color: trendColor),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(
                isFav ? Icons.star : Icons.star_border,
                color: isFav ? Colors.amber : Colors.grey,
                size: 20,
              ),
              onPressed: () => _toggleFav(n),
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.blue),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: const [
                Icon(Icons.wifi_tethering, size: 40, color: Colors.white),
                SizedBox(height: 6),
                Text('WiFi Scanner Pro',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                Text('Developer: ടോണിക്സ്',
                    style: TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home),
            title: const Text('ഹോം'),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.star),
            title: Text('ഫേവറിറ്റ്സ് (${favorites.length})'),
            onTap: () {
              Navigator.pop(context);
              setState(() {
                onlyFavorites = true;
                bandFilter = 'All';
              });
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.warning_amber, color: Colors.orange),
            title: Text('Rogue APs (${rogueGroups.length})'),
            onTap: () {
              Navigator.pop(context);
              _showRogueDialog();
            },
          ),
          ListTile(
            leading: const Icon(Icons.analytics),
            title: const Text('Channel Analysis'),
            onTap: () {
              Navigator.pop(context);
              _showChannelDialog();
            },
          ),
          ListTile(
            leading: const Icon(Icons.router),
            title: const Text('ESP32 Sync'),
            onTap: () {
              Navigator.pop(context);
              _showEsp32Dialog();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.file_upload),
            title: const Text('Export JSON'),
            onTap: () {
              Navigator.pop(context);
              _export('json');
            },
          ),
          ListTile(
            leading: const Icon(Icons.table_chart),
            title: const Text('Export CSV'),
            onTap: () {
              Navigator.pop(context);
              _export('csv');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              _showSettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('എബൗട്ട്'),
            onTap: () {
              Navigator.pop(context);
              _showAbout();
            },
          ),
        ],
      ),
    );
  }

  void _showDetails(WifiNetwork n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isFav = favorites.contains(n.bssid);
          final h = history[n.bssid] ?? [];
          final risk = n.riskScore;
          final riskColor = risk >= 50
              ? Colors.red
              : risk >= 20
                  ? Colors.orange
                  : Colors.green;

          Widget kv(String k, String v, {Color? color}) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                        width: 130,
                        child: Text(k,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey))),
                    Expanded(
                        child: Text(v,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: color))),
                  ],
                ),
              );

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.65,
            maxChildSize: 0.92,
            builder: (_, ctrl) => ListView(
              controller: ctrl,
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.grey[400],
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          n.isHidden ? '(Hidden network)' : n.ssid,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      icon: Icon(
                          isFav ? Icons.star : Icons.star_border,
                          color: isFav ? Colors.amber : null),
                      onPressed: () {
                        _toggleFav(n);
                        setSheetState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: n.signalPercent / 100,
                  color: n.borderColor,
                  backgroundColor: n.borderColor.withOpacity(0.2),
                ),
                const SizedBox(height: 12),
                kv('BSSID', n.bssid),
                kv('Security', n.security),
                kv('Band', n.band),
                kv('Channel', '${n.channel}'),
                kv('Frequency', '${n.frequency} MHz'),
                kv('RSSI', '${n.rssi} dBm'),
                kv('Signal', '${n.signalPercent}%'),
                kv('Est. Max Speed', '~${n.estimatedSpeed} Mbps'),
                kv('Hidden', n.isHidden ? 'അതെ' : 'ഇല്ല'),
                kv('WPS', n.isWps ? 'അതെ ⚠️' : 'ഇല്ല'),
                kv('Risk Score', '$risk / 100', color: riskColor),
                kv('Capabilities', n.capabilities),
                const Divider(height: 24),
                const Text('Signal History (RSSI)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SizedBox(
                    height: 90,
                    child: h.isEmpty
                        ? const Center(child: Text('ഡാറ്റ ഇല്ല'))
                        : CustomPaint(
                            painter: SparkPainter(h),
                            size: Size.infinite)),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showRogueDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Text('Rogue AP Detection'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: rogueGroups.isEmpty
              ? const Text(
                  'സംശയകരമായ AP-കളൊന്നും കണ്ടെത്തിയില്ല.\n\n'
                  'ഒരേ SSID-യിൽ ഒന്നിലധികം BSSID കാണുമ്പോൾ '
                  'ഇവിടെ മുന്നറിയിപ്പ് കാണിക്കും.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: rogueGroups.length,
                  itemBuilder: (_, i) {
                    final e = rogueGroups[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('⚠️ "${e.key}" — ${e.value.length} APs',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            ...e.value.map((n) => Text(
                                '  • ${n.bssid}  ${n.security}  ${n.rssi} dBm',
                                style:
                                    const TextStyle(fontSize: 12))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showChannelDialog() {
    final cong = Analyzer.channelCongestion(networks);
    final best = Analyzer.recommendChannel(cong);
    final sorted = cong.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Channel Analysis'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('✅ ഏറ്റവും നല്ല ചാനൽ: $best',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green)),
              ),
              const SizedBox(height: 12),
              if (sorted.isEmpty)
                const Text('ഡാറ്റ ഇല്ല')
              else
                ...sorted.map((e) => Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                              width: 60,
                              child: Text('Ch ${e.key}',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.w500))),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: (e.value / sorted.first.value)
                                  .clamp(0.0, 1.0),
                              minHeight: 8,
                              color: e.key == best
                                  ? Colors.green
                                  : Colors.blueGrey,
                              backgroundColor: Colors.grey.shade300,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${e.value}'),
                        ],
                      ),
                    )),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showEsp32Dialog() {
    final ctrl = TextEditingController(
        text: widget.prefs.getString('esp32ip') ?? '192.168.4.1');
    bool loading = false;
    String? err;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.router),
              SizedBox(width: 8),
              Text('ESP32 Sync'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'ESP32 WiFi scan ഫലങ്ങൾ HTTP വഴി ലഭ്യമാക്കണം.\n'
                'Endpoint: http://<ip>/scan → JSON',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: 'ESP32 IP address',
                  border: OutlineInputBorder(),
                  hintText: '192.168.4.1',
                ),
                keyboardType: TextInputType.url,
                enabled: !loading,
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!,
                      style: const TextStyle(
                          color: Colors.red, fontSize: 12)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: loading ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: loading
                  ? null
                  : () async {
                      setDlg(() {
                        loading = true;
                        err = null;
                      });
                      try {
                        await _syncEsp32(ctrl.text.trim());
                        widget.prefs
                            .setString('esp32ip', ctrl.text.trim());
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setDlg(() {
                          loading = false;
                          err = 'Sync failed: $e';
                        });
                      }
                    },
              child: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sync'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Dark Mode'),
                value:
                    Theme.of(context).brightness == Brightness.dark,
                onChanged: (_) {
                  widget.onToggleTheme();
                  setDlg(() {});
                },
              ),
              SwitchListTile(
                title: const Text('Auto-refresh'),
                value: autoRefresh,
                onChanged: (v) {
                  setDlg(() => autoRefresh = v);
                  setState(() {});
                },
              ),
              ListTile(
                title: Text('Refresh interval: ${refreshSec}s'),
                subtitle: Slider(
                  value: refreshSec.toDouble(),
                  min: 5,
                  max: 60,
                  divisions: 11,
                  label: '${refreshSec}s',
                  onChanged: (v) {
                    setDlg(() => refreshSec = v.round());
                    setState(() {});
                    widget.prefs.setInt('refreshSec', refreshSec);
                    _startTimer();
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'WiFi Scanner Pro',
      applicationVersion: '2.0.0',
      applicationIcon:
          const Icon(Icons.wifi_tethering, size: 48),
      children: const [
        SizedBox(height: 8),
        Text('Developer: ടോണിക്സ്'),
        SizedBox(height: 8),
        Text(
            'Advanced WiFi scanning with rogue AP detection, '
            'risk scoring, channel analysis, signal history, '
            'and ESP32 sync support.'),
        SizedBox(height: 8),
        Text(
            '⚠️ Passive scanning only — no attack features included.',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

class ScanBubbles extends StatefulWidget {
  final List<WifiNetwork> networks;
  const ScanBubbles({super.key, required this.networks});
  @override
  State<ScanBubbles> createState() => _ScanBubblesState();
}

class _ScanBubblesState extends State<ScanBubbles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
  }
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: BubblePainter(widget.networks, _c.value),
          child: const SizedBox.expand(),
        ),
      );
}

class BubblePainter extends CustomPainter {
  final List<WifiNetwork> nets;
  final double t;
  BubblePainter(this.nets, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide / 2 - 20;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.blue.withOpacity(0.2);
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(center, maxR * i / 4, ring);
    }

    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = SweepGradient(
        colors: [Colors.transparent, Colors.blue.withOpacity(0.7)],
        stops: [0.7, 1.0],
        transform: GradientRotation(2 * pi * t - pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: maxR));
    canvas.drawCircle(center, maxR, sweep);

    for (final n in nets) {
      final dist = maxR * (1 - n.signalPercent / 130);
      final pos = Offset(
        center.dx + dist * cos(n.direction),
        center.dy + dist * sin(n.direction),
      );
      final r = 7 + n.signalPercent * 0.12;
      canvas.drawCircle(
          pos, r, Paint()..color = n.borderColor.withOpacity(0.8));
      canvas.drawCircle(
        pos,
        r,
        Paint()
          ..color = n.borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    canvas.drawCircle(center, 6, Paint()..color = Colors.blue);
    canvas.drawCircle(
        center,
        6 + 3 * sin(2 * pi * t),
        Paint()
          ..color = Colors.blue.withOpacity(0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant BubblePainter old) =>
      old.t != t || old.nets != nets;
}

class ChannelChart extends StatelessWidget {
  final List<WifiNetwork> networks;
  const ChannelChart({super.key, required this.networks});

  @override
  Widget build(BuildContext context) {
    final cong = Analyzer.channelCongestion(networks);
    final best = Analyzer.recommendChannel(cong);
    const channels = [1, 6, 11];
    final maxV =
        channels.map((c) => cong[c] ?? 0).reduce((a, b) => a > b ? a : b);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Channel Load',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('Best: Ch $best',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.green)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: channels.map((ch) {
                final v = cong[ch] ?? 0;
                final h = maxV == 0
                    ? 0.05
                    : (v / maxV).clamp(0.05, 1.0);
                return Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text('$v',
                            style: const TextStyle(fontSize: 10)),
                        Container(
                          height: 50 * h,
                          decoration: BoxDecoration(
                            color: ch == best
                                ? Colors.green
                                : Colors.blueGrey,
                            borderRadius:
                                const BorderRadius.vertical(
                                    top: Radius.circular(4)),
                          ),
                        ),
                        Text('Ch $ch',
                            style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class SparkPainter extends CustomPainter {
  final List<int> data;
  SparkPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final minV = data.reduce(min).toDouble();
    final maxV = data.reduce(max).toDouble();
    final range = (maxV - minV).clamp(1, 1000).toDouble();

    final grid = Paint()
      ..color = Colors.grey.withOpacity(0.2)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height * (1 - (data[i] - minV) / range);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.blue
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill, Paint()..color = Colors.blue.withOpacity(0.15));

    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height * (1 - (data[i] - minV) / range);
      canvas.drawCircle(
          Offset(x, y), 2.5, Paint()..color = Colors.blue);
    }
  }

  @override
  bool shouldRepaint(covariant SparkPainter old) => old.data != data;
}

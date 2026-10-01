import 'package:flutter/material.dart';
import '../services/data_broker.dart';
import '../utils/map_source.dart';

Future<void> showMapSourceDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const MapSourceDialog());

class MapSourceDialog extends StatefulWidget {
  const MapSourceDialog({super.key});
  @override
  State<MapSourceDialog> createState() => _MapSourceDialogState();
}

class _MapSourceDialogState extends State<MapSourceDialog> {
  final form = GlobalKey<FormState>();
  String selected = MapSource.current.id;
  final url = TextEditingController(
    text: DataBroker.getValue<String>(0, 'MapCustomUrl', '') ?? '',
  );
  final attribution = TextEditingController(
    text: DataBroker.getValue<String>(0, 'MapCustomAttribution', '') ?? '',
  );
  @override
  void dispose() {
    url.dispose();
    attribution.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return AlertDialog(
      title: Text(zh ? '地图源' : 'Map source'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  items: [
                    for (final s in MapSource.builtIn)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                    DropdownMenuItem(
                      value: 'custom',
                      child: Text(zh ? '自定义 XYZ' : 'Custom XYZ'),
                    ),
                  ],
                  onChanged: (v) => setState(() => selected = v ?? 'osm'),
                ),
                if (selected == 'custom') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: url,
                    decoration: const InputDecoration(
                      labelText: 'XYZ URL',
                      hintText: 'https://example.com/{z}/{x}/{y}.png',
                    ),
                    validator: (v) =>
                        MapSource.validateTemplate(v ?? '') == null
                        ? null
                        : (zh
                              ? '请输入包含 {z}、{x}、{y} 的有效 HTTP(S) 地址'
                              : MapSource.validateTemplate(v ?? '')),
                  ),
                  TextFormField(
                    controller: attribution,
                    decoration: InputDecoration(
                      labelText: zh ? '地图版权说明' : 'Attribution',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  zh
                      ? '自定义地图须使用 WGS84 / Web Mercator（EPSG:3857）XYZ 瓦片。高德、腾讯等 GCJ-02 瓦片会使电台位置偏移。可用性取决于网络和地图服务商。'
                      : 'Use WGS84 / Web Mercator (EPSG:3857) XYZ tiles. GCJ-02 layers shift radio positions. Availability depends on your network and provider.',
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            DataBroker.dispatch(
              deviceId: 0,
              name: 'MapCustomUrl',
              data: url.text.trim(),
            );
            DataBroker.dispatch(
              deviceId: 0,
              name: 'MapCustomAttribution',
              data: attribution.text.trim(),
            );
            DataBroker.dispatch(deviceId: 0, name: 'MapSource', data: selected);
            Navigator.pop(context);
          },
          child: Text(zh ? '应用' : 'Apply'),
        ),
      ],
    );
  }
}

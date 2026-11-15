// Minimal native `plugin list --json` document, with current load provenance.
Map<String, dynamic> magpiePluginList(
  List<String> ids, {
  String spec = '/synthetic/loongpass',
}) => {
  'plugins': [
    <String, dynamic>{'spec': spec},
  ],
  'loaded': [
    <String, dynamic>{
      'spec': spec,
      'provides': ['loongpass'],
    },
  ],
  'providers': [
    <String, dynamic>{
      'id': 'loongpass',
      'spec': spec,
      'signedIn': ids.isNotEmpty,
      'accounts': [
        for (final id in ids) {'accountId': id},
      ],
    },
  ],
};

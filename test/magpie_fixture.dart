// Minimal native `plugin list --json` document, with current load provenance.
Map<String, dynamic> magpiePluginList(List<String> ids) => {
  'plugins': [
    <String, dynamic>{'spec': '/synthetic/loongpass'},
  ],
  'loaded': [
    <String, dynamic>{
      'spec': '/synthetic/loongpass',
      'provides': ['loongpass'],
    },
  ],
  'providers': [
    <String, dynamic>{
      'id': 'loongpass',
      'spec': '/synthetic/loongpass',
      'signedIn': ids.isNotEmpty,
      'accounts': [
        for (final id in ids) {'accountId': id},
      ],
    },
  ],
};

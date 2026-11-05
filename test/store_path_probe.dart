import 'dart:io';
Future<void> main()async{final root=await Directory('loongpass-minimax-actions-20261104/evidence').createTemp('probe-');final d=await root.createTemp('sub-');print(d.absolute.path);print(await d.resolveSymbolicLinks());print((await d.stat()).mode.toRadixString(8));print(await FileSystemEntity.type(d.absolute.path,followLinks:false));await d.delete();await root.delete();}

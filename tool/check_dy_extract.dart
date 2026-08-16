import 'package:kmxzs/services/flv_extractor.dart';

Future<void> main() async {
  final ex = FlvExtractor();
  final url =
      'https://www.douyin.com/?aid=70348af7-49e4-439a-aa02-b68d5dbbf7a9&modal_id=7633250733304125903&type=general';
  final r = await ex.extract(url);
  print('ok=${r.ok}');
  print(r.summary());
}

import "package:kmxzs/services/flv_extractor.dart";
void main() async {
  final r = await FlvExtractor().extract("https://www.youtube.com/watch?v=Za-TLXLfSMs");
  final u = r.bestUrl();
  print("ok=${r.ok} len=${u.length} hasComma=${u.contains(",")} hasM3u8=${u.contains("m3u8")}");
  print(u.substring(0, 120));
  print("...");
  print(u.substring(u.length > 80 ? u.length - 80 : 0));
}

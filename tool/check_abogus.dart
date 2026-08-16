import 'package:kmxzs/services/douyin_abogus.dart';

void main() {
  const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';
  const qs =
      'aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN&browser_language=zh-CN&browser_platform=Win32&browser_name=Chrome&browser_version=116.0.0.0&web_rid=123456&msToken=';
  const expected =
      'E7mhBmg6mEVNgf6X53/LfY3q6Rp3YAC80HViMD2fcdVS8639HMYm9exomQvvCASjEG/MIeYjy4hbO3xprQAjM36UHWwEUdQ2mgWkKl5Q5I0j53iruyRDntmF4vj3SFlm5XNAEOk0y75rKb70Woqe-vIlO62-zo0/9Uj=';
  final got = DouyinABogus(fixedStartMs: 1785498421000).sign(qs, userAgent: ua);
  print(got);
  print(got == expected ? 'MATCH' : 'MISMATCH');
}

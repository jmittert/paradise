module main
i64 main() {
  i64[] arr = {0,0,0,0};
  arr[0] = 1;
  arr[1] = 2;
  arr[2] = 3;
  arr[3] = 4;
  i64 w = arr[0];
  i64 x = arr[1];
  i64 y = arr[2];
  i64 z = arr[3];
  return ((z - y) + x) * w;
}

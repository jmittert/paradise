module main
i64 main() {
    i64[] data1 = {1,2,3,4,5,6,7,8,9,10};
    i64[] data2 = {1,2,3,4,5,6,7,8,9,10};

    i64[] sqrs = {0,0,0,0,0,0,0,0,0,0};
    [|sqrs = data1 .* data2 |];

    i64[] exp = {1,4,9,16,25,36,49,64,81,100};

    i64 i = 0;
    i64 ret = 3;
    while (i < 10) {
        if (exp[i] != sqrs[i]) {
            ret = 1;
        }
        i = i + 1;
    }
    return ret;
}

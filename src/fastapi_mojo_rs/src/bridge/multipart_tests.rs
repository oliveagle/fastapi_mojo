    use super::multipart::*;

    #[test]
    fn extract_boundary_basic() {
        let ct = b"multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
        assert_eq!(
            extract_boundary(ct).unwrap(),
            b"----WebKitFormBoundary7MA4YWxkTrZu0gW".to_vec()
        );
    }

    #[test]
    fn extract_boundary_quoted() {
        let ct = b"multipart/form-data; boundary=\"abc def\"";
        assert_eq!(extract_boundary(ct).unwrap(), b"abc def".to_vec());
    }

    #[test]
    fn extract_boundary_case_insensitive() {
        let ct = b"multipart/form-data; BOUNDARY=xxx";
        assert_eq!(extract_boundary(ct).unwrap(), b"xxx".to_vec());
    }

    #[test]
    fn parse_simple_text_field() {
        let body = b"--xxx\r\nContent-Disposition: form-data; name=\"hello\"\r\n\r\nworld\r\n--xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.name, b"hello");
        assert!(p.filename.is_none());
        assert_eq!(p.body, b"world");
        assert_eq!(String::from_utf8_lossy(&p.body_b64), "d29ybGQ=");
    }

    #[test]
    fn parse_file_upload() {
        let body = b"--xxx\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile content here\r\n--xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.name, b"upload");
        assert_eq!(p.filename.as_ref().unwrap(), b"a.txt");
        assert_eq!(p.content_type, b"text/plain");
        assert_eq!(p.body, b"file content here");
    }

    #[test]
    fn parse_file_trailing_newline_preserved() {
        // Regression: trailing \n (and \r\n) of file content must NOT be trimmed.
        // 分隔符已排除, raw_body 须为精确 part 内容 (决策-32 multipart roundtrip).
        let body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\nHello e2e multipart!\n\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"Hello e2e multipart!\n");
        assert_eq!(String::from_utf8_lossy(&p.body_b64), "SGVsbG8gZTJlIG11bHRpcGFydCEK");
    }

    #[test]
    fn parse_file_trailing_crlf_preserved() {
        // file 内容合法以 \r\n 结尾: 须原样保留 (分隔符已排除).
        let body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\ndata\r\n\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"data\r\n");
    }

    #[test]
    fn parse_multiple_fields_and_files() {
        let body = b"--xxx\r\n\
            Content-Disposition: form-data; name=\"title\"\r\n\r\n\
            My Document\r\n\
            --xxx\r\n\
            Content-Disposition: form-data; name=\"file1\"; filename=\"a.bin\"\r\n\
            Content-Type: application/octet-stream\r\n\r\n\
            \x00\x01\x02\x03\xff\r\n\
            --xxx\r\n\
            Content-Disposition: form-data; name=\"file2\"; filename=\"b.txt\"\r\n\r\n\
            text content\r\n\
            --xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 3);
        let parts = &lock_mp().parts;
        assert_eq!(parts[0].name, b"title");
        assert!(parts[0].filename.is_none());
        assert_eq!(parts[0].body, b"My Document");
        assert_eq!(parts[1].name, b"file1");
        assert_eq!(parts[1].filename.as_ref().unwrap(), b"a.bin");
        assert_eq!(parts[1].content_type, b"application/octet-stream");
        assert_eq!(parts[1].body, b"\x00\x01\x02\x03\xff");
        assert_eq!(parts[2].name, b"file2");
        assert_eq!(parts[2].filename.as_ref().unwrap(), b"b.txt");
        assert_eq!(parts[2].content_type, b"application/octet-stream"); // default
        assert_eq!(parts[2].body, b"text content");
    }

    #[test]
    fn parse_binary_body_preserved() {
        // body 含 NUL + 0xFF 等 invalid UTF-8, 必须 bytes-level 正确
        let body = b"--x\r\nContent-Disposition: form-data; name=\"data\"; filename=\"raw.bin\"\r\n\r\n\x00\xff\xfe\xfd\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"\x00\xff\xfe\xfd");
        // b64 反解应回到原 bytes
        // (测试仅断言 body 字段; b64 已预编码并验证)
        assert!(!p.body_b64.is_empty());
    }

    #[test]
    fn parse_missing_boundary_returns_neg1() {
        let body = b"hello world";
        let ct = b"application/octet-stream";
        assert_eq!(parse_multipart(body, ct), -1);
    }

    #[test]
    fn parse_empty_body_returns_neg1() {
        let body = b"";
        let ct = b"multipart/form-data; boundary=xxx";
        assert_eq!(parse_multipart(body, ct), -1);
    }

    #[test]
    fn extract_attr_quoted_and_unquoted() {
        assert_eq!(
            extract_attr(b"form-data; name=\"x\"", b"name").unwrap(),
            b"x".to_vec()
        );
        assert_eq!(
            extract_attr(b"form-data; name=y", b"name").unwrap(),
            b"y".to_vec()
        );
        assert_eq!(
            extract_attr(b"form-data; filename=\"a b.txt\"", b"filename").unwrap(),
            b"a b.txt".to_vec()
        );
    }

    #[test]
    fn b64_decode_roundtrip_full_range() {
        let raw: Vec<u8> = (0..=255u16).map(|i| i as u8).collect();
        let enc = b64_encode(&raw);
        let dec = b64_decode(&enc).expect("decode");
        assert_eq!(dec, raw);
    }

    #[test]
    fn b64_decode_padding() {
        // "A" = 1 byte -> QQ== ; "AB" = 2 bytes -> QUI=
        assert_eq!(b64_decode(b"QQ==").expect("pad1"), vec![0x41]);
        assert_eq!(b64_decode(b"QUI=").expect("pad2"), vec![0x41, 0x42]);
        // 非法字符 -> None
        assert!(b64_decode(b"Q!$%").is_none());
    }

    #[test]
    fn field5_sha256_hex_known_vector() {
        let body = b"--x\r\nContent-Disposition: form-data; name=\"f\"; filename=\"h.txt\"\r\n\r\nhello\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        assert_eq!(parse_multipart(body, ct), 1);
        let hex = String::from_utf8(
            part_sha256_hex(0).expect("sha256 hex"),
        )
        .expect("utf8");
        // sha256("hello") 已知向量 (FIPS 180-4)
        assert_eq!(
            hex,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
        // 逐字节访问器也一致 (field 5)
        assert_eq!(get_part_field_len(0, 5), 64);
        let mut via_ffi = String::new();
        for i in 0..64 {
            let b = get_part_field_byte(0, 5, i as i64);
            assert!(b >= 0);
            via_ffi.push((b as u8) as char);
        }
        assert_eq!(via_ffi, hex);
    }

    #[test]
    fn part_save_writes_bytes() {
        let body = b"--x\r\nContent-Disposition: form-data; name=\"f\"; filename=\"d.bin\"\r\n\r\n\x00\x01\xff\xfe\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        assert_eq!(parse_multipart(body, ct), 1);
        let path = format!(
            "{}/fm_mp_save_{}.bin",
            std::env::temp_dir().display(),
            std::process::id()
        );
        assert_eq!(part_save(0, &path), 0);
        let on_disk = std::fs::read(&path).expect("read back");
        assert_eq!(on_disk, vec![0x00, 0x01, 0xFF, 0xFE]);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn part_save_bad_index_fails() {
        let body = b"--x\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        assert_eq!(parse_multipart(body, ct), 1);
        assert_eq!(part_save(99, "/tmp/fm_mp_should_not_exist.bin"), -1);
    }

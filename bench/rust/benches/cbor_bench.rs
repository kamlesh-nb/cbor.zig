use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use serde::{Deserialize, Serialize};
use serde_cbor;

#[derive(Serialize, Deserialize, Clone)]
struct NestedStruct {
    id: u64,
    name: String,
    values: Vec<f64>,
    flags: Vec<bool>,
}

#[derive(Serialize, Deserialize, Clone)]
struct TestData {
    small_int: u32,
    medium_string: String,
    large_array: Vec<u64>,
    nested_struct: NestedStruct,
}

fn create_test_data() -> TestData {
    TestData {
        small_int: 42,
        medium_string: "This is a medium string for complex data testing".to_string(),
        large_array: (0..1000).map(|i| i * i).collect(),
        nested_struct: NestedStruct {
            id: 999999,
            name: "complex_nested_structure_with_long_name".to_string(),
            values: (0..50).map(|i| i as f64 * 0.1).collect(),
            flags: (0..20).map(|i| i % 2 == 0).collect(),
        },
    }
}

fn bench_integer_encoding(c: &mut Criterion) {
    let mut group = c.benchmark_group("encode_integer");

    let test_values = vec![0u64, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296];

    for value in test_values {
        group.bench_with_input(BenchmarkId::new("integer", value), &value, |b, &value| {
            b.iter(|| {
                let encoded = serde_cbor::to_vec(&value).unwrap();
                black_box(encoded);
            });
        });
    }
    group.finish();
}

fn bench_string_encoding(c: &mut Criterion) {
    let mut group = c.benchmark_group("encode_string");

    let long_string = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ".repeat(5);
    let test_strings = vec![
        "A",
        "Hello, World!",
        "This is a medium-length string for testing CBOR encoding performance.",
        &long_string,
    ];

    for (_i, test_string) in test_strings.iter().enumerate() {
        group.bench_with_input(
            BenchmarkId::new("string", format!("len_{}", test_string.len())),
            test_string,
            |b, &test_string| {
                b.iter(|| {
                    let encoded = serde_cbor::to_vec(&test_string).unwrap();
                    black_box(encoded);
                });
            },
        );
    }
    group.finish();
}

fn bench_array_encoding(c: &mut Criterion) {
    let mut group = c.benchmark_group("encode_array");

    // Small array
    let small_array: Vec<u32> = vec![1, 2, 3, 4, 5];
    group.bench_function("small", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&small_array).unwrap();
            black_box(encoded);
        });
    });

    // Medium array
    let medium_array: Vec<u64> = (0..100).collect();
    group.bench_function("medium", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&medium_array).unwrap();
            black_box(encoded);
        });
    });

    // Large array
    let large_array: Vec<u64> = (0..10000).collect();
    group.bench_function("large", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&large_array).unwrap();
            black_box(encoded);
        });
    });

    group.finish();
}

fn bench_struct_encoding(c: &mut Criterion) {
    let mut group = c.benchmark_group("encode_struct");

    #[derive(Serialize, Deserialize)]
    struct SimpleStruct {
        id: u64,
        name: String,
        value: f64,
    }

    let test_struct = SimpleStruct {
        id: 12345,
        name: "test_name".to_string(),
        value: 3.14159,
    };

    group.bench_function("single", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&test_struct).unwrap();
            black_box(encoded);
        });
    });

    // Complex nested struct
    let complex_data = create_test_data();
    group.bench_function("array", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&complex_data).unwrap();
            black_box(encoded);
        });
    });

    group.finish();
}

fn bench_decode_integer(c: &mut Criterion) {
    let mut group = c.benchmark_group("decode_integer");

    let test_values = vec![0u64, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296];

    for value in test_values {
        let encoded = serde_cbor::to_vec(&value).unwrap();
        group.bench_with_input(
            BenchmarkId::new("integer", value),
            &encoded,
            |b, encoded| {
                b.iter(|| {
                    let decoded: u64 = serde_cbor::from_slice(encoded).unwrap();
                    black_box(decoded);
                });
            },
        );
    }
    group.finish();
}

fn bench_decode_string(c: &mut Criterion) {
    let mut group = c.benchmark_group("decode_string");

    let test_strings = vec![
        "A",
        "Hello, World!",
        "This is a medium-length string for testing CBOR encoding performance.",
    ];

    for test_string in test_strings {
        let encoded = serde_cbor::to_vec(&test_string).unwrap();
        group.bench_with_input(
            BenchmarkId::new("string", format!("len_{}", test_string.len())),
            &encoded,
            |b, encoded| {
                b.iter(|| {
                    let decoded: String = serde_cbor::from_slice(encoded).unwrap();
                    black_box(decoded);
                });
            },
        );
    }
    group.finish();
}

fn bench_decode_array(c: &mut Criterion) {
    let mut group = c.benchmark_group("decode_array");

    // Small array
    let small_array: Vec<u32> = vec![1, 2, 3, 4, 5];
    let small_encoded = serde_cbor::to_vec(&small_array).unwrap();
    group.bench_function("small", |b| {
        b.iter(|| {
            let decoded: Vec<u32> = serde_cbor::from_slice(&small_encoded).unwrap();
            black_box(decoded);
        });
    });

    // Medium array
    let medium_array: Vec<u64> = (0..100).collect();
    let medium_encoded = serde_cbor::to_vec(&medium_array).unwrap();
    group.bench_function("medium", |b| {
        b.iter(|| {
            let decoded: Vec<u64> = serde_cbor::from_slice(&medium_encoded).unwrap();
            black_box(decoded);
        });
    });

    // Large array
    let large_array: Vec<u64> = (0..10000).collect();
    let large_encoded = serde_cbor::to_vec(&large_array).unwrap();
    group.bench_function("large", |b| {
        b.iter(|| {
            let decoded: Vec<u64> = serde_cbor::from_slice(&large_encoded).unwrap();
            black_box(decoded);
        });
    });

    group.finish();
}

fn bench_decode_struct(c: &mut Criterion) {
    let mut group = c.benchmark_group("decode_struct");

    #[derive(Serialize, Deserialize)]
    struct SimpleStruct {
        id: u64,
        name: String,
        value: f64,
    }

    let test_struct = SimpleStruct {
        id: 12345,
        name: "test_name".to_string(),
        value: 3.14159,
    };
    let simple_encoded = serde_cbor::to_vec(&test_struct).unwrap();

    group.bench_function("single", |b| {
        b.iter(|| {
            let decoded: SimpleStruct = serde_cbor::from_slice(&simple_encoded).unwrap();
            black_box(decoded);
        });
    });

    // Complex nested struct
    let complex_data = create_test_data();
    let complex_encoded = serde_cbor::to_vec(&complex_data).unwrap();
    group.bench_function("array", |b| {
        b.iter(|| {
            let decoded: TestData = serde_cbor::from_slice(&complex_encoded).unwrap();
            black_box(decoded);
        });
    });

    group.finish();
}

fn bench_roundtrip(c: &mut Criterion) {
    let mut group = c.benchmark_group("roundtrip");

    // Array roundtrip
    let test_array: Vec<u64> = (0..100).collect();
    group.bench_function("array", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&test_array).unwrap();
            let decoded: Vec<u64> = serde_cbor::from_slice(&encoded).unwrap();
            black_box(decoded);
        });
    });

    // Struct roundtrip
    let test_data = create_test_data();
    group.bench_function("struct", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&test_data).unwrap();
            let decoded: TestData = serde_cbor::from_slice(&encoded).unwrap();
            black_box(decoded);
        });
    });

    // Map roundtrip
    use std::collections::HashMap;
    let mut map = HashMap::new();
    for i in 0..50 {
        map.insert(format!("key_{}", i), i as u64);
    }
    group.bench_function("map", |b| {
        b.iter(|| {
            let encoded = serde_cbor::to_vec(&map).unwrap();
            let decoded: HashMap<String, u64> = serde_cbor::from_slice(&encoded).unwrap();
            black_box(decoded);
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_integer_encoding,
    bench_string_encoding,
    bench_array_encoding,
    bench_struct_encoding,
    bench_decode_integer,
    bench_decode_string,
    bench_decode_array,
    bench_decode_struct,
    bench_roundtrip
);
criterion_main!(benches);

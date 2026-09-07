# SRCNN HWPE 프로젝트 최종 정리

작성일: 2026-04-15
경로: `/home/dahun/junsik/SRCNN/project_summary.md`

---

## 1. 프로젝트 개요

**목표:** PULPissimo SoC + Genesys2 FPGA에서 SRCNN 추론 가속기 구현

- **Base SoC**: PULPissimo (CV32E40P RISC-V core, RV32IMC)
- **FPGA**: Digilent Genesys2 (Xilinx Kintex-7 xc7k325t)
- **클럭**: soc_clk 20 MHz, per_clk 10 MHz, DDR3 MIG ref_clk 200 MHz
- **Network**: SRCNN 3-Layer
  - L1: 1ch → 4ch, 3×3 kernel, ReLU
  - L2: 4ch → 4ch, 3×3 kernel, ReLU
  - L3: 4ch → 1ch, 3×3 kernel, no ReLU (final reconstruction)
  - Padding = 1, Q8.8 fixed-point
- **입력**: 150×150 grayscale 이미지

---

## 2. 하드웨어 구조

### 2.1 모듈 계층

```
CV32E40P (CPU)
    │
    │ (TCDM 32-bit ×4 bank, APB CSR)
    │
fc_hwpe (top controller, FSM)
    ├── hwpe_im2col       ─── TCDM → (Line Buffer) → DDR3 AXI
    ├── hwpe_axi_dma      ─── DDR3 AXI → BRAM (double buffer)
    ├── hwpe_weight_buf   ─── TCDM → FF register
    ├── hwpe_systolic_array ─ 4×16 = 64 PE Output-Stationary
    └── hwpe_post_proc    ─── 4×int32 acc → L2 TCDM write
```

### 2.2 모듈별 cycle당 입출력

| 모듈 | Input (per cycle) | Output (per cycle) | 내부 리소스 |
|---|---|---|---|
| **hwpe_im2col** | TCDM 32-bit (2 pixel) | DDR3 AXI 256-bit (16-beat burst) | Line buffer 4 replica × 32KB |
| **hwpe_axi_dma** | DDR3 AXI 256-bit | BRAM 256-bit (double buffer) | Double BRAM |
| **hwpe_weight_buf** | TCDM 32-bit | 64-bit broadcast (4×int16) | FF register |
| **hwpe_systolic_array** | ACT 256-bit + WGT 64-bit | 4ch × 32-bit acc (tile 끝) | 64 DSP48E1, 64 PE |
| **hwpe_post_proc** | 4ch × 32-bit acc + 4×int16 bias | TCDM 32-bit (1 int16 pixel) | Combinational |

### 2.3 fc_hwpe Top FSM

```
S_IDLE → S_IM2COL → S_DMA_LOAD → S_LOAD_W → S_RUN → S_DONE → S_IDLE
```
(배치 단위 반복, CPU가 매 배치마다 트리거)

### 2.4 hwpe_im2col 내부 FSM (최종, AXI burst 버전)

```
S_IDLE → S_LOAD_REQ → S_LOAD_WAIT → S_LOAD_W0 → S_LOAD_W1
                         │                         │
                         └─────(반복: 모든 ch/row/col)──┘
                                 │
                                 ▼
                           (LOAD 완료)
                                 │
                                 ▼
                         S_AW → S_COMP → S_W → S_COMP → … → S_B
                          │    (5cy/beat)  (16 beat burst)    │
                          │                                   │
                          └──────(다음 burst 혹은 k 전환)────┘
                                 │
                                 ▼
                              S_DONE
```

**핵심 최적화 포인트**:
- 4 replica BRAM으로 **cycle당 4 pixel 병렬 read**
- 17 cycle / 16 pixel 파이프라인 (phase 0~4, 4 issue + 1 drain)
- AXI INCR burst **최대 16 beat**, 4KB boundary 런타임 분할

### 2.5 데이터 경로

```
L2 (input) → TCDM read → HW im2col(Line Buffer) → DDR3 AXI burst write
                                                    │
                                                    ▼
DDR3 → AXI DMA 256-bit read → BRAM double-buffer → Systolic Array
                                                         │
                                           ┌────────────┘
                                           ▼
                                    64 PE MAC 누적 (k_total cycle)
                                           │
                                           ▼
                                   Drain: 매 cycle 4ch × 32-bit
                                           │
                                           ▼
                                    post_proc (>>8, +bias, ReLU, clamp)
                                           │
                                           ▼
                                       L2 TCDM write (output)
```

### 2.6 Systolic Array 상세

| 항목 | 값 |
|---|---|
| PE 구성 | 4 row (channel) × 16 col (pixel) = 64 PE |
| DSP48E1 | PE당 1개 → 총 64개 |
| cycle당 MAC | 64 MAC/cycle |
| 처리 방식 | Output-Stationary (k개 누적 후 drain) |
| COMPUTE phase | k_total cycle (k=9 for L1, k=36 for L2/L3) |
| DRAIN phase | 16 cycle (매 cycle 4ch × 32-bit → post_proc) |

### 2.7 AXI Read/Write Mux

- **Write**: CPU 직결 / HWPE im2col 공유 (2:1 arbiter)
- **Read**: CPU / HWPE DMA 공유 (2:1 arbiter, CPU 우선)

---

## 3. 최종 성능 (현재 최적화 상태 @ 20 MHz)

### 3.1 HWPE Breakdown (실측, PASS)

| 구간 | 시간 | 비율 |
|---|---|---|
| **IM2COL** | **79.03 ms** | **71.3%** |
| DMA_LOAD | 10.03 ms | 9.1% |
| LOAD_W | 1.06 ms | 1.0% |
| RUN | 20.68 ms | 18.7% |
| ├ systolic busy | 5.90 ms | (28% of RUN) |
| └ post_proc write | 14.77 ms | (71% of RUN) |
| **TOTAL** | **110.81 ms** | 100% |

### 3.2 Per-Layer 소요 (HWPE only, ms)

| Layer | IM2COL | DMA | LOAD_W | RUN | Total |
|---|---|---|---|---|---|
| L1 (1→4, K=9) | 7.12 | 1.12 | 0.05 | 6.82 | 15.12 |
| L2 (4→4, K=36) | 35.95 | 4.45 | 0.80 | 8.73 | 49.95 |
| L3 (4→1, K=36) | 35.95 | 4.45 | 0.20 | 5.12 | 45.73 |

### 3.3 FPS (20 MHz 기준)

| 측정 범위 | 시간 | FPS |
|---|---|---|
| HWPE 순수 실행 | 110.81 ms | **9.02 FPS** |
| HWPE + CPU overhead (추정 ~60ms) | ~170 ms | ~5.9 FPS |

### 3.4 GOPS / DSP 효율

- MAC per output pixel: L1 36 + L2 144 + L3 36 = **216 MAC**
- Frame: 216 × 22,500 = **4.86 M MAC** = 9.72 M Ops
- 실효 @9 FPS = 9.72M × 9.02 = **87.7 MOps/s = 0.088 GOPS**
- Peak DSP @20MHz = 64 × 2 × 20M = **2.56 GOPS**
- **실효율 = 3.4%** (IM2COL/post_proc가 systolic을 못 따라가서 낮음)

---

## 4. 정확도

- 실제 학습된 SRCNN weight + 실제 150×150 이미지
- 22,500 pixel 중 **16,554 exact match (73.6%)**
- **Max abs diff = 3**, **Mean abs diff = 0.31** (Q8.8 3-layer 누적 rounding)
- **PASS** (허용치 max ≤ 3)

---

## 5. 최적화 이력

| 단계 | HWPE Total | IM2COL | Speedup (누적) |
|---|---|---|---|
| CPU im2col (baseline) | 8,760 ms | — | 1× |
| HW im2col naive (single-beat AXI) | 287 ms | 256 ms | 30.5× |
| Line Buffer (1 cy/pixel pipeline) | 232 ms | 200 ms | 37.8× |
| 4-way parallel BRAM read (4 replica) | 163.5 ms | 131.7 ms | 53.6× |
| **+ AXI burst 16-beat (최종)** | **110.8 ms** | **79.0 ms** | **79.1×** |

### 5.1 각 단계 설명

1. **CPU → HW im2col (30×)**: im2col 연산을 CPU 대신 하드웨어가 수행
2. **Line Buffer (1.24×)**: TCDM 중복 read (9×) 제거, BRAM에 한 번만 캐시
3. **4-way parallel (1.42×)**: BRAM을 4 replica로 두고 cycle당 4 pixel 병렬 read
4. **AXI burst (1.48×)**: single-beat → 16-beat burst로 AW/B 오버헤드 amortize

### 5.2 이전 시도 후 폐기한 것

| 시도 | 결과 | 사유 |
|---|---|---|
| AXI Burst Write (초기 시도, 04/08) | 출력 값 깨짐 | 4KB boundary 미처리 → 04/15 재시도 성공 |
| Internal Batch Loop + Pipelining | DMA hang | FSM 복잡도 → 롤백 |

---

## 6. 리소스 (Kintex-7 xc7k325t, Vivado 실측)

| 리소스 | 사용 / 전체 | 사용률 |
|---|---|---|
| **LUT** | 63,257 / 203,800 | 31.0% |
| **FF** | 38,139 / 407,600 | 9.4% |
| **BRAM36** | 196 / 445 | 44.0% |
| **DSP48E1** | 77 / 840 | 9.2% |
| **Timing (WNS)** | +0.040 ns | 0 violation |

### 6.1 DSP 분배 추정

| 용도 | DSP 수 |
|---|---|
| Systolic MAC (64 PE) | 64 |
| CV32E40P MUL | ~4 |
| AXI/MIG/기타 | ~9 |

### 6.2 BRAM 주요 분배 추정

| 블록 | BRAM36 수 |
|---|---|
| hwpe_im2col line buffer (4 replica × 32KB) | ~32 |
| DMA double-buffer | ~16 |
| TCDM L2 (128KB) | ~32 |
| I$/D$ cache | ~16 |
| MIG/PULPissimo 주변 | ~100 |

---

## 7. 식별된 병목 분석

### 7.1 초기 프로파일링 (04/08, naive HW im2col)

| 상태 | 시간 (@20MHz) | 비율 |
|---|---|---|
| **S_IM2COL** | **255.67 ms** | **88.9%** |
| S_DMA_LOAD | 10.03 ms | 3.5% |
| S_LOAD_W | 1.06 ms | 0.4% |
| S_RUN | 20.69 ms | 7.2% |
| **합계** | **287.47 ms** | 100% |

**핵심 인사이트**: Systolic Array 확장은 효과 없음 (실제 MAC은 전체의 2%). im2col이 진짜 병목.

### 7.2 최적화 후 병목 (04/15, 최종)

| 상태 | 시간 | 비율 |
|---|---|---|
| **S_IM2COL** | **79.03 ms** | **71.3%** |
| S_DMA_LOAD | 10.03 ms | 9.1% |
| S_RUN | 20.68 ms | 18.7% |

IM2COL 최적화로 89% → 71%로 줄었으나 여전히 지배적.
S_RUN 내부에서 post_proc L2 write(14.77ms)가 systolic(5.90ms)보다 2.5× 큼.

### 7.3 근본 원인: TCDM 32-bit 병목

TCDM = Tightly Coupled Data Memory (L2 SRAM, 4 bank × 32-bit interleaved).
CPU가 32-bit 코어라서 TCDM 포트도 32-bit. HWPE 입장에서는 **좁은 통로**.

| TCDM 경유 동작 | throughput | 병목 기여 |
|---|---|---|
| im2col LOAD (input read) | 32-bit/cy = 2 pixel | IM2COL의 ~38% |
| post_proc write (output) | 32-bit/cy = 1 pixel | RUN의 71% |
| weight buf read | 32-bit/cy | 무시 가능 |

AXI(256-bit)를 쓰는 DDR3 경로는 상대적으로 빠름.

---

## 8. 적용하지 않은 최적화 및 발전 가능성

### 8.1 단기 최적화 (현재 구조 유지)

| 옵션 | 예상 효과 | 난이도 | 미적용 사유 |
|---|---|---|---|
| post_proc 4-port TCDM write | -11 ms (→100 ms) | 중 | Bank 충돌 해결(stride 조정) 필요 |
| D2: per-channel LOAD/COMP overlap | -24 ms (→87 ms) | 중상 | im2col FSM 분리 필요 |
| D1: cross-batch overlap (internal loop) | -30 ms (→80 ms) | 상 | 이전 시도 DMA hang 경험 |

### 8.2 아키텍처 변경: TCDM → DDR3 직통 (핵심 발전 방향)

#### 현재의 근본 병목

현재 입출력 데이터가 L2 TCDM(32-bit, @soc_clk)을 경유함:
- im2col LOAD: **L2 TCDM → line buffer** (32-bit, 2 pixel/cycle)
- post_proc write: **결과 → L2 TCDM** (32-bit, 1 pixel/cycle)
- 두 경로가 HWPE 전체의 **~40% (im2col LOAD ~30ms + post_proc ~15ms)** 차지

HWPE 클럭만 올려도 TCDM이 soc_clk에 묶여 있어 효과 제한적.

#### 제안 구조: DDR3 직통

```
[현재]
L2(TCDM 32-bit) ──read──► im2col ──AXI 256-bit write──► DDR3
DDR3 ──AXI read──► DMA ──► Systolic ──► post_proc ──TCDM write──► L2

[제안]
DDR3 ──AXI 256-bit read──► im2col ──AXI 256-bit write──► DDR3
DDR3 ──AXI 256-bit read──► DMA ──► Systolic ──► post_proc ──AXI 256-bit write──► DDR3
```

- Input/output 전부 DDR3에 배치
- TCDM은 weight/bias (수백 바이트)만 담당
- Layer 연결: L1 output → DDR3 region A, L2 input ← region A (자연스러움)

#### AXI 포트 시분할 (추가 포트 불필요)

fc_hwpe FSM 상태별로 AXI read/write 사용자가 다름 → 기존 2 포트(read 1, write 1)로 충분:

| fc_hwpe 상태 | AXI Read 사용 | AXI Write 사용 |
|---|---|---|
| S_IM2COL | im2col (input read) | im2col (im2col matrix write) |
| S_DMA_LOAD | DMA (im2col matrix read) | (idle) |
| S_RUN | (idle) | post_proc (output write) |

#### 성능 예상

**im2col LOAD**: TCDM 32-bit(2 pix/cy) → AXI 256-bit burst(16 pix/beat)
```
L2 batch 현재: 4ch × 5rows × 75 beats × 4cy = 6,000 cy/batch
L2 batch DDR3: 4ch × 5rows × 10 beats × ~2cy =   400 cy/batch  (15× 빠름)
```

**post_proc**: TCDM 1 pixel/cy → 16 pixel 버퍼링 후 AXI burst write
```
현재: 64 cy/tile (16 pix × 4ch 직렬)
DDR3:  8 cy/tile (4 beat × ~2cy)  (8× 빠름)
```

| 구간 | 현재 (TCDM) | DDR3 직통 | 절감 |
|---|---|---|---|
| IM2COL | 79.03 ms | ~50 ms | -29 ms |
| DMA_LOAD | 10.03 ms | 10 ms | 동일 |
| LOAD_W | 1.06 ms | 1 ms | 동일 |
| RUN | 20.68 ms | ~9 ms | -12 ms |
| **TOTAL** | **110.81 ms** | **~70 ms** | **-41 ms** |

→ **9 FPS → ~14 FPS** (20 MHz, HWPE only 기준)

#### 필요한 수정

| 대상 | 내용 |
|---|---|
| hwpe_im2col.sv | LOAD phase: TCDM read → AXI burst read |
| hwpe_post_proc.sv | TCDM write → 16-pixel buffer + AXI burst write |
| fc_hwpe.sv | AXI read/write mux에 post_proc, im2col-read 추가 |
| test.c | input/output 주소를 DDR3 region으로 변경 |

### 8.3 클럭 분리 (HWPE 독립 클럭)

#### 구조

```
soc_clk (20 MHz): CV32E40P, L2 TCDM, APB
hwpe_clk (별도):  im2col, systolic, DMA, post_proc
                   ↕ CDC FIFO
```

Vivado MMCM/PLL로 hwpe_clk 생성, TCDM/CSR 인터페이스에 CDC FIFO 삽입.

#### 클럭 분리 단독 (현재 TCDM 구조 유지)

| hwpe_clk | HWPE 예상 | FPS | 제한 |
|---|---|---|---|
| 20 MHz | 110.81 ms | 9 FPS | (현재) |
| 50 MHz | ~55 ms | ~18 FPS | TCDM 20MHz 고정 → LOAD/post_proc 못 따라감 |
| 100 MHz | ~62 ms | ~16 FPS | TCDM 병목 포화 |

→ TCDM 구조에서는 **클럭 올려도 한계 존재** (~16 FPS 포화)

#### 클럭 분리 + DDR3 직통 (조합 시)

| hwpe_clk | HWPE 예상 | FPS |
|---|---|---|
| 20 MHz | ~70 ms | ~14 FPS |
| 50 MHz | ~30 ms | ~33 FPS |
| 100 MHz | ~20 ms | ~50 FPS |

DDR3 직통 구조에서는 TCDM 병목이 없어 **클럭 효과가 선형에 가깝게** 적용됨.
100 MHz timing closure는 systolic DSP chain, im2col addr gen 등 critical path 검증 필요.

### 8.4 발전 로드맵 (요약)

```
[현재] 110 ms, 9 FPS @20MHz
    │
    ├─ (1) DDR3 직통 → ~70 ms, 14 FPS @20MHz
    │       │
    │       └─ (2) + HWPE 클럭 100MHz → ~20 ms, 50 FPS
    │
    ├─ (1') 단기 최적화만 → ~87 ms, 11 FPS @20MHz
    │       (D2 overlap + post_proc 4-port)
    │
    └─ (3) 이기종 채널 SW config → 성능 변화 없음, 확장성 확보
```

### 8.5 이기종 연산 지원 (SW 레벨)

현재 SRCNN은 1→4→4→1 고정 구성. 향후 다른 채널 구성(예: 1→8→8→1, 1→16→16→1)도
CSR 파라미터만 바꿔서 동일 HW로 처리하고 싶다면:

**RTL 변경 없이 가능한 것:**
- in_ch, out_ch, layer_num 등은 이미 CSR로 설정 가능
- SW에서 layer_config 구조체를 만들어 루프 돌리면 됨

**RTL 변경 필요한 것:**
- Systolic row > 4 (out_ch > 4): PE row 수 증가 필요
- Systolic col > 16: PE col 수 변경 필요
- 현재 MAX_IN_CH=4, MAX_OUT_CH=4가 하드코딩된 곳 파라미터화

**접근:**
1. 현재 4×16 systolic 범위 내 (out_ch ≤ 4)에서는 SW만으로 이기종 지원 가능
2. out_ch > 4 필요 시 systolic 확장 또는 multi-pass 처리

---

## 9. 지도교수 피드백 & 교훈

> "가속기만 보고 '2배 개선' 이라고 생각해도 SW에서 control 하는 부분이 오래 걸려서 실제 개선이 안 되는 경우가 많다. 전체 기본 구조를 fix하고 **분석을 딥하게 많이 하는 것이 중요**하다. 프로파일링으로 부분별 latency를 잘 나누고 ILA와 비교해서 room을 보는 게 더 중요하다."

### 이번 프로젝트에서 실증된 것

1. RTL에 per-FSM-state 카운터를 넣은 덕에 **"IM2COL이 89% 병목"** 이라는 사실을 정확히 파악 → systolic 확장 무용론 확인 (실제 MAC은 전체의 2%)
2. 블랙박스 측정이었다면 systolic을 2×/4× 늘리는 잘못된 최적화 방향으로 갔을 것
3. 최종적으로 im2col 단독 최적화만으로 HWPE 287 → 110 ms 달성

---

## 10. 논문 작성 시 강조 포인트

1. **HW im2col로 30× 가속** + **Line Buffer + 4-way + AXI burst로 추가 2.6× → 총 79× 가속** (CPU 대비)
2. **DSP 9.2%만 사용**해서 달성 (리소스 효율)
3. **Output-Stationary Systolic 4×16** — 배치 처리로 BRAM 용량 극복
4. **Line Buffer로 TCDM 중복 read 9× → 1×** 제거
5. **AXI INCR burst + 4KB boundary 런타임 분할**로 DDR3 효율화
6. **Deep profiling 방법론**: per-FSM-state 카운터 + sub-state 분석 → 병목 정확 파악
7. **정확도**: Max abs diff 3 (Q8.8 rounding), exact match 73.6%

---

## 11. 코드 구조 (주요 파일)

### 11.1 RTL (수정/추가된 HWPE 모듈)

| 파일 경로 | 역할 |
|---|---|
| `rtl/fc/fc_hwpe.sv` | HWPE top FSM, CSR 디코드, per-state 카운터 |
| `rtl/fc/hwpe_systolic_array.sv` | 4×16 PE Output-Stationary systolic |
| `rtl/fc/hwpe_axi_dma.sv` | DDR3→BRAM 256-bit AXI burst read |
| `rtl/fc/hwpe_weight_buf.sv` | L2→FF register weight load |
| `rtl/fc/hwpe_post_proc.sv` | >>8 + bias → ReLU → clamp, TCDM write |
| `rtl/fc/hwpe_im2col.sv` | **핵심 최적화 대상**. Line Buffer + 4-way + AXI burst |

(RTL base: `pulpissimo/.bender/git/checkouts/pulp_soc-b7e7c62781de8fd8/`)

### 11.2 SW

| 파일 | 역할 |
|---|---|
| `sw/regression_tests/tcdm_tests/srcnn_test/test.c` | 메인 테스트 (CPU 배치 loop, 프로파일 출력) |
| `sw/regression_tests/tcdm_tests/srcnn_test/srcnn_data.h` | 학습된 weight/bias/input/golden |

### 11.3 HWPE CSR 주요 offset (test.c 기준)

| Offset | 이름 | 용도 |
|---|---|---|
| 0x040 | REG_POSTPROC_BASE | post_proc 출력 L2 base |
| 0x044 | REG_POSTPROC_OFF | 배치별 출력 offset |
| 0x048 | REG_WEIGHT | L2 weight base |
| 0x04C | REG_BIAS | L2 bias base |
| 0x050 | REG_IN_CH | 입력 채널 수 |
| 0x054 | REG_OUT_CH | 출력 채널 수 |
| 0x058 | REG_LAYER_NUM | 레이어 번호 (1,2,3) |
| 0x060 | REG_DDR_ADDR | im2col DDR3 target base |
| 0x064 | REG_TILE_LEN | systolic tile 길이 |
| 0x068 | REG_TOTAL_PIX | 전체 픽셀 수 (padded) |
| 0x06C | REG_BATCH_PIX | 현 배치의 pixel 수 |
| 0x080 | REG_HW_CYCLES | HWPE 총 사이클 |
| 0x084 | REG_IM2COL_ADDR | im2col 입력 base |
| 0x088 | REG_IM2COL_SIZE | img_w, img_h |
| 0x08C | REG_IM2COL_BSTART | 배치 시작 pixel index |
| 0x090 | REG_CNT_IM2COL | IM2COL state 사이클 |
| 0x094 | REG_CNT_DMA | DMA_LOAD state 사이클 |
| 0x098 | REG_CNT_LOADW | LOAD_W state 사이클 |
| 0x09C | REG_CNT_RUN | RUN state 사이클 |
| 0x0A0 | REG_CNT_SYS | systolic busy 사이클 |
| 0x0A4 | REG_CNT_PP | post_proc writing 사이클 |

### 11.4 메모리 레이아웃

| 주소 | 용도 | 크기 |
|---|---|---|
| `0x1C019000` | L2_WEIGHT | 512 B |
| `0x1C019200` | L2_BIAS | 32 B |
| `0x1C019400` | L2_OUT_A | ~180 KB (4ch × 22,512 × 2) |
| `0x1C045400` | L2_OUT_B | ~180 KB |
| `0x80000000` | DDR3 base (MIG) | im2col 중간 결과 |

### 11.5 배치 구성 (L1/L2/L3)

| Layer | k_total | pix_per_k | batch_pix | batch_cnt |
|---|---|---|---|---|
| L1 (1→4, K=9) | 9 | 1,808 | 1,808 | 13 |
| L2 (4→4, K=36) | 36 | 448 | 448 | 51 |
| L3 (4→1, K=36) | 36 | 448 | 448 | 51 |
| **합계** | | | | **115 배치** |

---

## 12. 백업 현황 (2026-04-15 기준)

| 파일 | 경로 |
|---|---|
| 비트스트림 | `/home/dahun/junsik/SRCNN/backup_bitstream/xilinx_pulpissimo_im2col_burst_pass_20260415.bit` |
| SW | `/home/dahun/junsik/SRCNN/backup_sw/test_im2col_burst_pass_20260415.c` |
| RTL | `/home/dahun/junsik/SRCNN/backup_rtl/hwpe_im2col_burst_pass_20260415.sv` |

---

## 13. 빌드/실행 절차 (기록용)

### 비트스트림 빌드
```bash
export PATH=/home/dahun/tools/Vivado/2023.2/bin:$PATH
export PULPISSIMO_ROOT=/home/dahun/junsik/SRCNN/pulpissimo
cd /home/dahun/junsik/SRCNN/pulpissimo/target/fpga/pulpissimo-genesys2
make clean
cd .. && make genesys2
```

### SW 빌드
```bash
export PATH=/home/dahun/junsik/SRCNN/pulp_tools/bin:$PATH
source /home/dahun/junsik/SRCNN/pulpissimo/sw/pulp-runtime/configs/pulpissimo.sh
cd /home/dahun/junsik/SRCNN/pulpissimo/sw/regression_tests/tcdm_tests/srcnn_test
make clean all platform=fpga io=uart
```

### 보드 실행 (Genesys2 serial: 200300B9E664)
```bash
# HW server
/home/dahun/tools/Vivado/2023.2/bin/hw_server -s tcp::3133

# OCD
openocd -c "gdb port 3343" -c "tcl port 6676" -c "telnet port 4456" \
        -c "adapter serial 200300B9E664" -f openocd-genesys2.cfg

# Minicom
stty -F /dev/ttyUSB0 115200 raw -echo && cat /dev/ttyUSB0

# GDB
riscv32-unknown-elf-gdb build/srcnn_test/srcnn_test
# target remote localhost:3343; monitor reset halt; load; continue
```

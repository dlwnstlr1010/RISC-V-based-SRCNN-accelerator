# SRCNN HWPE 디버그 인수인계 문서

작성일: 2026-04-17 (저녁)
상태: **DDR3 직통 아키텍처 구현 후 L3 정확도 실패 (max_diff=261, 52~93% 스케일로 저하)**

---

## 1. 최종 목표

**5가지 SRCNN config을 동일 HW에서 CSR만으로 전환**하여 논문 claim 확보:
- C1: 1-4-4-1 (기본)
- C2: 1-8-8-1
- C3: 1-16-16-1
- C4: 1-4-8-1 (비대칭)
- C5: 1-8-16-1

핵심 가치: **Reconfigurable SR accelerator** (GPU 대비 reconfig time/power 우위).

이를 위해 **DDR3 직통 아키텍처**가 필요 (L2=176KB로 16채널 중간결과 못 담음 → DDR3 사용).

---

## 2. 현재 진행 상태

### 최근 완료된 작업
1. **Phase 1 RTL 확장**: `MAX_IN_CH=16`, `K_MAX=144` 적용 — C1 검증 PASS (기존과 동일)
2. **DDR3 직통 RTL 재작성**:
   - `hwpe_im2col.sv`: TCDM read 제거 → AXI AR/R 추가, 256-bit wide line buffer (4 replica)
   - `hwpe_post_proc.sv`: TCDM write 제거 → AXI burst write, 2D buffer 구조 재설계
   - `fc_hwpe.sv`: AXI muxing (read: im2col/DMA, write: im2col/post_proc), TCDM 포트 0/2 해제, `agen_start` 비활성화
3. **test.c 재작성**: input/layer outputs을 DDR3 주소로 (`DDR_INPUT=0x80000000`, `DDR_OUT_A=0x80400000`, `DDR_OUT_B=0x80800000`, `DDR_IM2COL=0x80C00000`)
4. **L2_WEIGHT/L2_BIAS를 고주소 이동** (`0x1C060000`/`0x1C061000`): .rodata 성장으로 인한 overlap 방지

### 현재 진행 중 (이 시점)
**가설: `weight_q` 배열이 K_MAX=144로 커지면서 Vivado가 BRAM으로 추론 → 1-cycle latency로 systolic MAC이 off-by-one k에서 weight 읽음 → 잘못된 MAC 결과**

**대응**: `hwpe_weight_buf.sv`에 `(* ram_style = "registers" *)` 속성 추가하여 강제 register 합성.

**다음 단계**: 비트스트림 재빌드 (40분) 후 C1 테스트. 맞으면 PASS (max_diff ≤ 3), 틀리면 다른 원인.

---

## 3. 증상 및 검증된 것

### 증상
```
[verify] HWPE out[0..4] = 45 68 70 76 83
[verify] Golden[0..4]   = 87 86 88 88 89
[verify] exact=306/22500 max_diff=261 mean_diff=36.15
```

- 코너에서 에러 최대(52% scale), 가장자리에서 감소(93% scale)
- 평균 mean_diff=36, 전체 약 **60% 스케일**로 낮아짐
- Systematic error (랜덤이 아님)

### 검증 완료 (문제 없음)

**데이터 체인 전체 정상**:
1. CPU → DDR3 input memcpy OK (`[DUMP] input[0..7] = 87 87 88 88 89 89 90 90` ✓)
2. L1 output OK:
   - ch0, ch1 = 0 (ReLU 자연 결과, sa_acc=-5161 → 음수 → 0)
   - ch2 = `142 110 110 111`, ch3 = `218 267 269 271` (non-zero)
3. L2 output OK (모든 채널 non-zero 합리적 값)
4. L3 im2col matrix가 L2 output과 정확히 일치:
   - `k=4` (ic=0) = L2 ch0
   - `k=13` (ic=1) = L2 ch1
   - `k=22` (ic=2) = L2 ch2
   - `k=31` (ic=3) = L2 ch3
5. Weight 로드 OK: `weight[0][0]=-35, weight[0][2]=-42` (debug 확인)
6. Bias 로드 OK: `srcnn_b3[0]=9`, `L2_BIAS[0]=9` 일치

### 추측되는 버그 (현재 시도 중인 가설)

- **K_MAX=144가 `weight_q`를 BRAM으로 추론시킴**
- BRAM 1-cycle latency → systolic MAC이 k_q[T]에서 weight[r][k_q[T-1]] 읽음
- 결과적으로 모든 MAC이 off-by-one weight로 계산됨
- Output이 시스테메틱하게 틀어짐 (~60% 스케일)

**대응 코드**: `hwpe_weight_buf.sv` 76번 줄
```systemverilog
(* ram_style = "registers" *) logic signed [15:0] weight_q [MAX_OUT_CH-1:0][K_MAX-1:0];
```

---

## 4. 시도했지만 해결 안 된 것

| # | 시도 | 결과 |
|---|---|---|
| 1 | `post_proc`의 loop unroll (explicit buf_q[0..3] write) | 증상 동일 |
| 2 | `wr_ch_q` 3-bit 확장, 비교 로직 견고화 | 증상 동일 |
| 3 | `agen_start=0`으로 addr_gen 비활성화 (TCDM 경합 제거) | CPU hang 일부 해결, 정확도 동일 |
| 4 | `L2_WEIGHT/L2_BIAS` 0x1C060000으로 이동 | CPU hang 해결, 정확도 동일 |
| 5 | bias 누락 가설 검증 | 기각 (bias=9 정상 로드 확인) |
| 6 | im2col AXI read 데이터 무결성 검증 | OK (L3 im2col matrix = L2 output 일치) |

### 깊이 의심하던 가설들 (검증 완료, 문제 아님)
- CPU→DDR3 memcpy가 부정확 → 검증 OK
- post_proc가 ch0, ch1 skip → 검증 OK (ReLU 자연 결과)
- L2 output이 틀어져서 L3 입력 오류 → L2 output 정상
- im2col AXI read vs CPU read 불일치 → 일치함
- im2col word 정렬 버그 → 모든 값 정확히 일치

---

## 5. 파일 경로 및 주요 수정 위치

### RTL 파일 (수정됨)
- `/home/dahun/junsik/SRCNN/pulpissimo/.bender/git/checkouts/pulp_soc-b7e7c62781de8fd8/rtl/fc/`
  - `hwpe_im2col.sv` — 256-bit line buffer, AXI read
  - `hwpe_post_proc.sv` — AXI burst write, 2D buf_q
  - `hwpe_weight_buf.sv` — K_MAX=144, registers 속성 추가 (최신)
  - `hwpe_systolic_array.sv` — K_MAX=144, k_q 8-bit
  - `fc_hwpe.sv` — AXI mux, agen_start=0, TCDM port 0/2 tie off

### SW
- `/home/dahun/junsik/SRCNN/pulpissimo/sw/regression_tests/tcdm_tests/srcnn_test/test.c` — DDR3 레이아웃, 디버그 프린트 다수

### 백업 (안전)
- `/home/dahun/junsik/SRCNN/backup_bitstream/xilinx_pulpissimo_im2col_burst_pass_20260415.bit` — OLD PASS 검증된 비트스트림
- `/home/dahun/junsik/SRCNN/backup_sw/test_im2col_burst_pass_20260415.c` — OLD PASS test.c
- `/home/dahun/junsik/SRCNN/backup_rtl/pre_reconfigurable_20260417/` — RTL 전체 백업

### 현재 비트스트림
- `/home/dahun/junsik/SRCNN/pulpissimo/target/fpga/pulpissimo-genesys2/pulpissimo-genesys2.runs/impl_1/xilinx_pulpissimo.bit` (04-17 18:20 기준, `ram_style=registers` 수정 전)

---

## 6. 다음 단계 (새 채팅에서 이어받을 때)

### 즉시 할 일
1. **비트스트림 재빌드** (40분):
```bash
export PATH=/home/dahun/tools/Vivado/2023.2/bin:$PATH
hash -r
export PULPISSIMO_ROOT=/home/dahun/junsik/SRCNN/pulpissimo
cd /home/dahun/junsik/SRCNN/pulpissimo/target/fpga/pulpissimo-genesys2
make clean
cd ..
make genesys2
```

2. **보드 프로그래밍 + 실행** (기존 test.c 재사용)

### 결과 분기
- **PASS (max_diff ≤ 3)**: `ram_style=registers` 가설 맞음. 안정 버전 확보. 5 config 구현으로 진행
- **여전히 FAIL**: 다음 가설 탐색
  - Vivado synth log 확인해서 weight_q가 실제로 BRAM/register 어디로 갔는지 검증
  - ModelSim RTL 시뮬레이션으로 systolic MAC 동작 확인
  - 필요시 DDR3 직통 포기하고 L2 기반으로 5 config 중 가능한 것만 구현 (예: 64×64 이미지로 스케일 다운)

### 궁극적 방향
5 config 동작 → GPU (RTX 3090) vs HWPE의 **reconfig time + power** 비교 → 논문

### 절대 하지 말 것
- Backup 파일들 삭제 금지 (`backup_rtl/pre_reconfigurable_20260417` 특히 중요)
- `ram_style=registers` 이외의 RTL 변경 (문제 지점 이동 방지)

---

## 7. 디버그 히스토리 요약 (새 채팅에서 컨텍스트 잃었을 때 참고)

### 타임라인
1. DDR3 직통 RTL 작성 → 첫 빌드
2. 첫 실행: CPU가 `weight/bias copy start`에서 hang (L1 진입 직후)
3. 가설 1: addr_gen TCDM 독점 → `agen_start=0`으로 비활성화 → 빌드 → 여전히 hang
4. 가설 2: `.rodata` 성장으로 L2_WEIGHT와 overlap → `L2_WEIGHT=0x1C060000` → CPU hang 해결
5. 모든 layer PASS 하지만 정확도 FAIL (max_diff=261)
6. 데이터 체인 전체 검증 → 모두 정상
7. 가설 3: weight_q가 BRAM으로 추론되어 1-cy 지연 → `ram_style=registers` 적용 → **현재 상태**

### 핵심 로그 (최근 성공 실행)
```
[L1] PASSED
L1 ch0 = 0 (자연 ReLU)
L1 ch2 [0..3] = 142 110 110 111
L1 ch3 [0..3] = 218 267 269 271

[L2] PASSED
L2 ch0 [0..7] = 32 112 109 109 101 101 148 101
L2 ch1 [0..7] = 229 163 152 154 210 167 135 213
L2 ch2 [0..7] = 253 386 382 386 397 380 398 405
L2 ch3 [0..7] = 213 96 109 112 107 73 215 80

[L3] PASSED
L3 im2col k=4 = L2 ch0 ✓
L3 im2col k=13 = L2 ch1 ✓
L3 im2col k=22 = L2 ch2 ✓
L3 im2col k=31 = L2 ch3 ✓

[verify] HWPE = 45 68 70 76 83
[verify] Golden = 87 86 88 88 89
max_diff=261, mean=36
```

---

## 8. 추가 검증 아이디어 (이 가설이 틀린 경우)

### A) Synthesis log 확인
Vivado 빌드 후 `.rpt` 파일에서 `weight_q`가 BRAM인지 register인지 확인.
```bash
grep -i "weight_q\|RAM_style" /home/dahun/junsik/SRCNN/pulpissimo/target/fpga/pulpissimo-genesys2/pulpissimo-genesys2.runs/synth_1/*.rpt
```

### B) RTL Simulation
ModelSim/Xsim에서 systolic_array + weight_buf만 따로 TB로 돌려 MAC 결과 검증.

### C) Fallback 전략
DDR3 직통 포기하고:
- 이미지 64×64로 축소 (16-ch 중간결과 131KB로 L2 가능)
- OLD RTL (TCDM 기반) 복구
- 5 config 구현
- 논문 claim 축소: "현재 L2 용량 한계로 작은 이미지", future work: DDR3 확장

---

## 끝

이 문서로 새 채팅에서 바로 이어받을 수 있습니다. `ram_style=registers` 빌드 결과가 나오면 이 파일에 기록하고 다음 단계 결정.

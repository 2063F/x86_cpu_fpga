# x86_cpu_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する x86互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

x86 命令セットのサブセットを段階的に実装し、最終的にアセンブリで書いた
ゲームプログラムを実行できる CPU + SoC を構築します。

## 開発ロードマップ

| Phase | 内容 | 状態 |
|:------|:-----|:-----|
| 1 | 開発環境セットアップ & LED点滅 | ✅ 完了 |
| 2 | 基本コンポーネント (ALU, レジスタ, メモリ) | ✅ 完了 |
| 3 | 最小限CPUコア (8086互換) | ✅ 完了 (シミュレーション検証、実機は未確認) |
| 4 | UART & デバッグ環境 | 🔧 次のステップ |
| 5 | 8086命令セット拡張 | ⬜ |
| 6 | 32ビット拡張 (i386) | ⬜ |
| 7 | SDRAMコントローラ | ⬜ |
| 8 | 周辺機器 & ゲーム環境 | ⬜ |

## ディレクトリ構成

```
x86_cpu_fpga/
├── src/                      # Verilog ソースファイル
│   ├── x86_defines.vh        # 共通定義 (ALU演算コード, レジスタ番号, CPUステート等)
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   ├── alu.v                 # 32ビットALU (x86フラグ完全対応)
│   ├── register_file.v       # x86レジスタファイル (8/16/32bit対応)
│   ├── memory_controller.v   # メモリコントローラ (8KB B-SRAM, 同期読み出し)
│   ├── cpu_core.v            # CPUコア (8086互換サブセット, Phase 3)
│   └── soc_top.v             # 実機用トップ (CPU + メモリ + LED/ボタン I/O)
├── sim/                      # テストベンチ
│   ├── tb_blinky.v
│   ├── tb_alu.v
│   ├── tb_register_file.v
│   ├── tb_memory_controller.v
│   ├── tb_cpu_core.v         # CPUコア テスト (自己診断プログラムを実行)
│   ├── tb_cpu_cosim.v        # 差分テスト用トレース出力 (tools/cosim.py が使用)
│   ├── tb_soc_top.v          # 実機用トップのテスト (LEDデモを実行)
│   └── programs/
│       ├── cpu_test.asm      # 自己診断プログラム (NASM)
│       └── cpu_test.hex      # ↑ のアセンブル結果 ($readmemh 形式)
├── firmware/                 # 実機で動かすプログラム
│   ├── led_demo.asm          # LEDカウンタ デモ (NASM)
│   └── led_demo.hex          # ↑ のアセンブル結果 (B-SRAM の初期値)
├── tools/
│   ├── bin2hex.py            # NASM の出力 (.bin) → .hex 変換
│   └── cosim.py              # Unicorn エミュレータとの差分テスト
├── constraints/              # FPGA制約ファイル
│   ├── tang_primer_25k.cst   # ピン制約
│   └── timing.sdc            # タイミング制約
└── README.md
```

## CPUコア (Phase 3)

`src/cpu_core.v` は 16ビット リアルモードで動作するマルチサイクル CPU です。
`alu.v` と `register_file.v` を内部で使用し、`memory_controller.v` と接続して動作します。
リセット後は `F000:FFF0` から実行を開始します。

### 実行の流れ

```
FETCH → MODRM → DISP → IMM → EA → LOAD → EXECUTE → STORE
```

命令に不要なステートは飛ばします (例: `MOV AX, imm16` は FETCH → IMM → EXECUTE)。
メモリは同期読み出しのため、読み出し 1 回に 2 クロックかかります
(FETCH・MODRM・DISP・IMM・LOAD が各 2 クロック、EA・EXECUTE・STORE が各 1 クロック)。
自己診断プログラムでの平均は 1 命令あたり約 5.3 クロックです。

### 実装済みの命令

| 分類 | 命令 |
|:-----|:-----|
| データ転送 | `MOV` (レジスタ/メモリ/即値/セグメントレジスタ/moffs), `LEA`, `PUSH`, `POP` |
| 算術・論理 | `ADD` `OR` `ADC` `SBB` `AND` `SUB` `XOR` `CMP` `TEST` `INC` `DEC` `NOT` `NEG` |
| 分岐 | `JMP` (short/near/far/間接), `Jcc`, `CALL` (near/間接), `RET`, `LOOP` `LOOPE` `LOOPNE` `JCXZ` |
| フラグ | `CLC` `STC` `CMC` `CLI` `STI` `CLD` `STD` |
| I/O | `IN` `OUT` (imm8 / DX) |
| その他 | `NOP`, `HLT`, セグメントオーバーライド (`ES:` `CS:` `SS:` `DS:`) |

アドレッシングモードは 16ビットの ModR/M 全種類 (`[BX+SI+disp]` など) に対応しています。

### 未実装 (Phase 5 以降)

割り込み (`INT`/`IRET`)、ストリング命令 (`MOVS` 等と `REP`)、シフト・ローテート、`MUL`/`DIV`、
far `CALL`/`RETF`、`PUSHF`/`POPF`、`XCHG` など。
未実装の命令を実行しようとすると CPU は停止し、`fault` 出力が 1 になります
(`dbg_ip` / `dbg_opcode` で場所と命令コードを確認できます)。

### 外部インターフェース

| 信号 | 説明 |
|:-----|:-----|
| `mem_addr` `mem_wdata` `mem_rdata` `mem_size` `mem_rd` `mem_wr` `mem_ready` | メモリバス。`mem_ready` が 1 になるまで要求を保持するので、ウェイトを挿入するメモリも接続可能 |
| `io_addr` `io_wdata` `io_rdata` `io_size` `io_rd` `io_wr` | I/O ポートバス (`IN`/`OUT` 命令) |
| `halted` | `HLT` で停止中 |
| `fault` | 未実装命令で停止中 |
| `inst_done` `dbg_ip` `dbg_opcode` | デバッグ用 (命令完了パルス、実行中の命令の IP とオペコード) |

## 実機で動かす (Tang Primer 25K)

`src/soc_top.v` は CPUコア・メモリ・LED/ボタンをまとめた実機用のトップモジュールです。
ピン名は `blinky.v` と同じなので、`constraints/` のファイルをそのまま使えます。

> シミュレーションと yosys での合成確認までで、実機ではまだ動作確認していません。

### Gowin EDA での手順

1. プロジェクトに次のファイルを追加します。
   - `src/soc_top.v` `src/cpu_core.v` `src/alu.v` `src/register_file.v`
     `src/memory_controller.v` `src/x86_defines.vh`
   - `constraints/tang_primer_25k.cst` `constraints/timing.sdc`
2. トップモジュールを `soc_top` にします (`blinky.v` は不要です)。
3. 合成・配置配線して書き込みます。

メモリの初期値は `firmware/led_demo.hex` から読み込みます (`soc_top` の `INIT_FILE` パラメータ)。
相対パスのため、合成時にファイルが見つからない場合は `INIT_FILE` を絶対パスに変更してください。

### 期待する動作 (led_demo)

- 2 個の LED が 2 進カウンタとして `00 → 01 → 10 → 11 → 00 …` と変化します (1 ステップ約 0.26 秒)。
- ユーザーボタンを押している間は逆向きにカウントします。
- リセットボタンで `00` から再開します。
- 2 個の LED が交互に点滅し続ける場合は、CPU が未実装命令で停止しています (`fault`)。

### 合成後に確認する点

- リソース使用量: B-SRAM が 4 ブロック使われていること
  (yosys での概算は LUT 約 5,800 / 23,040、FF 約 400、B-SRAM 4)。
  B-SRAM が 0 でLUT が大幅に増えている場合は、メモリが B-SRAM として推論されていません。
- タイミング: 50 MHz (20 ns) を満たしていること。満たさない場合はクロックを下げる必要があります。

### I/O ポート

| ポート | 方向 | 内容 |
|:-------|:-----|:-----|
| `0x00` | 書き込み / 読み出し | LED レジスタ (bit 0 = `led[0]`, bit 1 = `led[1]`) |
| `0x01` | 読み出し | ボタン (bit 0 = ユーザーボタン) |

### プログラムの変更

`firmware/led_demo.asm` を変更したら `.hex` を作り直して、再度合成します。

```bash
nasm -f bin -o firmware/led_demo.bin firmware/led_demo.asm
python3 tools/bin2hex.py firmware/led_demo.bin firmware/led_demo.hex
```

## ターゲットボード

- **FPGA**: Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
- **LUT4**: 23,040
- **FF**: 23,040
- **B-SRAM**: 1,008 Kbits (56ブロック)
- **クロック**: 50 MHz

## シミュレーション実行方法

コマンドはすべてリポジトリのルートで実行します。

### Icarus Verilog を使用する場合

```bash
# ALU テスト
iverilog -I src -o sim/tb_alu.out sim/tb_alu.v src/alu.v
vvp sim/tb_alu.out

# レジスタファイル テスト
iverilog -I src -o sim/tb_regfile.out sim/tb_register_file.v src/register_file.v
vvp sim/tb_regfile.out

# メモリコントローラ テスト
iverilog -I src -o sim/tb_mem.out sim/tb_memory_controller.v src/memory_controller.v
vvp sim/tb_mem.out

# CPUコア テスト (自己診断プログラム cpu_test.hex を実行)
iverilog -I src -o sim/tb_cpu_core.out sim/tb_cpu_core.v src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v
vvp sim/tb_cpu_core.out

# 実機用トップ テスト (firmware/led_demo.hex を実行)
iverilog -I src -o sim/tb_soc_top.out sim/tb_soc_top.v src/soc_top.v src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v
vvp sim/tb_soc_top.out
```

CPUコア テストに `+trace` を付けると、実行した命令ごとにレジスタの値を表示します。

```bash
vvp sim/tb_cpu_core.out +trace
```

### テストプログラムの再アセンブル

`sim/programs/cpu_test.asm` を変更した場合は `.hex` を作り直します。

```bash
nasm -f bin -o sim/programs/cpu_test.bin sim/programs/cpu_test.asm
python3 tools/bin2hex.py sim/programs/cpu_test.bin sim/programs/cpu_test.hex
```

### Unicorn エミュレータとの差分テスト

実装済みの命令からランダムなプログラムを生成し、CPUコア (RTL) と x86 エミュレータ
[Unicorn](https://www.unicorn-engine.org/) の両方で実行して、1 命令ごとのレジスタ・フラグ、
メモリ書き込み、I/O アクセスを比較します。CPUコアを変更したら実行してください。

```bash
pip install unicorn

python3 tools/cosim.py              # 200 シード
python3 tools/cosim.py -n 1000      # シード数を増やす
python3 tools/cosim.py --stall      # メモリにランダムなウェイトを挿入して実行
python3 tools/cosim.py --seed 42    # 失敗したシードを再現
```

### 波形表示

```bash
gtkwave tb_alu.vcd
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
- **NASM** - x86アセンブラ
- **Python 3 + Unicorn** - 差分テスト (任意)
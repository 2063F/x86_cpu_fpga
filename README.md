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
| 3 | 最小限CPUコア (8086互換) | 🔧 次のステップ |
| 4 | UART & デバッグ環境 | ⬜ |
| 5 | 8086命令セット拡張 | ⬜ |
| 6 | 32ビット拡張 (i386) | ⬜ |
| 7 | SDRAMコントローラ | ⬜ |
| 8 | 周辺機器 & ゲーム環境 | ⬜ |

## ディレクトリ構成

```
x86_cpu_fpga/
├── src/                      # Verilog ソースファイル
│   ├── x86_defines.vh        # 共通定義 (ALU演算コード, レジスタ番号等)
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   ├── alu.v                 # 32ビットALU (x86フラグ完全対応)
│   ├── register_file.v       # x86レジスタファイル (8/16/32bit対応)
│   └── memory_controller.v   # メモリコントローラ (8KB B-SRAM)
├── sim/                      # テストベンチ
│   ├── tb_blinky.v
│   ├── tb_alu.v
│   ├── tb_register_file.v
│   └── tb_memory_controller.v
├── constraints/              # FPGA制約ファイル
│   ├── tang_primer_25k.cst   # ピン制約
│   └── timing.sdc            # タイミング制約
└── README.md
```

## ターゲットボード

- **FPGA**: Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
- **LUT4**: 23,040
- **FF**: 23,040
- **B-SRAM**: 1,008 Kbits (56ブロック)
- **クロック**: 50 MHz

## シミュレーション実行方法

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
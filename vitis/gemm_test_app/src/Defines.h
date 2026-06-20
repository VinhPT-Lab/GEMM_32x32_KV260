#ifndef SRC_DEFINES_H_
#define SRC_DEFINES_H_

#include "xparameters.h"
#include "xaxidma_hw.h"
#include "xil_types.h"

// ============================================================
// Cache / data type
// ============================================================
#define CACHE_LINE_SIZE 32

#define DATA_TYPE s8
#define MAX_LIMIT 127
#define MIN_LIMIT -128

// ============================================================
// GEMM_TOP AXI Lite base address
// ============================================================
#define MM_ADDR             XPAR_GEMM_TOP_0_BASEADDR

#define SHIFT_ADDR          (MM_ADDR + 0x00)
#define FL_ADDR             (MM_ADDR + 0x04)
#define FWBN_ADDR           (MM_ADDR + 0x08)
#define WWBN_ADDR           (MM_ADDR + 0x0C)

// ============================================================
// AXI DMA base addresses
// DMA 0: Feature input
// DMA 1: Weight input
// DMA 2: Result output
// ============================================================
#define FEATURE_DMA_ADDR    XPAR_AXI_DMA_0_BASEADDR
#define WEIGHT_DMA_ADDR     XPAR_AXI_DMA_1_BASEADDR
#define RESULT_DMA_ADDR     XPAR_AXI_DMA_2_BASEADDR

// ============================================================
// AXI DMA MM2S register map
// MM2S = Memory Map to Stream = DDR -> accelerator
// ============================================================
#define FEATURE_MM2S_DMACR      (FEATURE_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_CR_OFFSET)
#define FEATURE_MM2S_DMASR      (FEATURE_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET)
#define FEATURE_MM2S_SA         (FEATURE_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET)
#define FEATURE_MM2S_SA_MSB     (FEATURE_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_MSB_OFFSET)
#define FEATURE_MM2S_LENGTH     (FEATURE_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_BUFFLEN_OFFSET)

#define WEIGHT_MM2S_DMACR       (WEIGHT_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_CR_OFFSET)
#define WEIGHT_MM2S_DMASR       (WEIGHT_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET)
#define WEIGHT_MM2S_SA          (WEIGHT_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET)
#define WEIGHT_MM2S_SA_MSB      (WEIGHT_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_MSB_OFFSET)
#define WEIGHT_MM2S_LENGTH      (WEIGHT_DMA_ADDR + XAXIDMA_TX_OFFSET + XAXIDMA_BUFFLEN_OFFSET)

// ============================================================
// AXI DMA S2MM register map
// S2MM = Stream to Memory Map = accelerator -> DDR
// ============================================================
#ifndef XAXIDMA_DESTADDR_OFFSET
#define XAXIDMA_DESTADDR_OFFSET XAXIDMA_SRCADDR_OFFSET
#endif

#ifndef XAXIDMA_DESTADDR_MSB_OFFSET
#define XAXIDMA_DESTADDR_MSB_OFFSET XAXIDMA_SRCADDR_MSB_OFFSET
#endif

#define RESULT_S2MM_DMACR       (RESULT_DMA_ADDR + XAXIDMA_RX_OFFSET + XAXIDMA_CR_OFFSET)
#define RESULT_S2MM_DMASR       (RESULT_DMA_ADDR + XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET)
#define RESULT_S2MM_DA          (RESULT_DMA_ADDR + XAXIDMA_RX_OFFSET + XAXIDMA_DESTADDR_OFFSET)
#define RESULT_S2MM_DA_MSB      (RESULT_DMA_ADDR + XAXIDMA_RX_OFFSET + XAXIDMA_DESTADDR_MSB_OFFSET)
#define RESULT_S2MM_LENGTH      (RESULT_DMA_ADDR + XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET)

// ============================================================
// DMA status / control masks
// ============================================================
#ifndef XAXIDMA_CR_RUNSTOP_MASK
#define XAXIDMA_CR_RUNSTOP_MASK 0x00000001U
#endif

#ifndef XAXIDMA_CR_RESET_MASK
#define XAXIDMA_CR_RESET_MASK   0x00000004U
#endif

#ifndef XAXIDMA_IDLE_MASK
#define XAXIDMA_IDLE_MASK       0x00000002U
#endif

// Simple DMA error bits:
// bit 4 = DMAIntErr
// bit 5 = DMASlvErr
// bit 6 = DMADecErr
#define DMA_ERROR_MASK          0x00000070U

// ============================================================
// Systolic array / accelerator parameters
// ============================================================
#define A_SIZE 32

#define W_block_num 4096
#define F_in_block_num 4096
#define F_out_Block_num 4096

#define F_length_width 10
#define F_width_block_num_width 6
#define W_width_block_num_width 6
#define shift_width 5

// ============================================================
// Matrix size limits
// Note: C/C++ khong co toan tu **.
// Sai: 2 ** F_length_width
// Dung: 1U << F_length_width
// ============================================================
#define F_IN_MATRIX_SIZE_MAX    (F_in_block_num * A_SIZE)
#define W_MATRIX_SIZE_MAX       (W_block_num * A_SIZE)
#define F_OUT_MATRIX_SIZE_MAX   (F_out_Block_num * A_SIZE)

#define F_LENGTH_MAX            (1U << F_length_width)
#define F_WIDTH_MAX             ((1U << F_width_block_num_width) * A_SIZE)
#define W_LENGTH_MAX            F_WIDTH_MAX
#define W_WIDTH_MAX             ((1U << W_width_block_num_width) * A_SIZE)

#endif

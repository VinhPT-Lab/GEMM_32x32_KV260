#ifndef FPGA_WIN_MOCK_H
#define FPGA_WIN_MOCK_H

#include <stdbool.h>
#include <stdint.h>

static inline bool fpga_win_mock_available(void) {
    return false;
}

#endif  // FPGA_WIN_MOCK_H

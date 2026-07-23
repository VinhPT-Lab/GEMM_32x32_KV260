
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

M = 64
K = 64
N = 64
P_SHIFT = 0
JOB_COUNT = 2
RESULT_FILE = Path(__file__).with_name("result_matrix.txt")
MAX_MISMATCH_DETAILS = 20

Matrix = List[List[int]]
BEGIN_RE = re.compile(r"^\s*MATRIX_BEGIN\s+JOB=(\d+)\b", re.IGNORECASE)
END_RE = re.compile(r"^\s*MATRIX_END\s+JOB=(\d+)\b", re.IGNORECASE)
INTEGER_RE = re.compile(r"[-+]?\d+")


def matrix_value_a(job_id: int, row: int, col: int) -> int:

    if row >= M or col >= K:
        return 0

    if job_id == 0:
        return ((row * 17 + col * 7 + (row % 5) * 3) % 29) - 14

    if ((row * 3 + col * 5 + 1) % 11) == 0:
        return 0
    return ((row * 7 + col * 19 + ((row + col) % 5) * 3 + 3) % 17) - 8


def matrix_value_b(job_id: int, row: int, col: int) -> int:
   
    if row >= K or col >= N:
        return 0

    if job_id == 0:
        return ((row * 5 + col * 11 + (col % 7) * 4) % 31) - 15

    if row == col:
        return (2, -1, 1, -2)[row % 4]
    return 0


def build_input_matrices(job_id: int) -> Tuple[Matrix, Matrix]:
   
    a = [[matrix_value_a(job_id, row, col) for col in range(K)] for row in range(M)]
    b = [[matrix_value_b(job_id, row, col) for col in range(N)] for row in range(K)]

    if job_id == 0:
        a[0][0] = 127
        a[0][1] = -128
        a[0][2] = 0
        a[0][3] = 1
        a[0][4] = -1
        a[M // 2][0] = -128
        a[M - 1][K - 1] = -1

        b[0][0] = 1
        b[1][0] = -1
        b[2][1] = 127
        b[3][2] = -128
        b[4][3] = 0
        b[5][4] = 1
        b[6][5] = -1
        b[K // 2][N // 2] = 127
        b[K - 1][N - 1] = -1
    else:
        a[0][0] = 7
        a[0][1] = -8
        a[M // 2][K // 2] = 0
        a[M - 1][K - 1] = -7

    return a, b


def quantize_to_int8(value: int, shift_amount: int) -> int:
 
    temp = value
    if shift_amount > 0:
        temp = (temp + (1 << (shift_amount - 1))) >> shift_amount
    return max(-128, min(127, temp))


def software_gemm(a: Matrix, b: Matrix) -> Matrix:
    
    result: Matrix = [[0 for _ in range(N)] for _ in range(M)]

    for row in range(M):
        for col in range(N):
            acc = 0
            for kk in range(K):
                acc += a[row][kk] * b[kk][col]
            result[row][col] = quantize_to_int8(acc, P_SHIFT)

    return result


def read_copied_matrices(path: Path) -> Dict[int, Matrix]:
   
    matrices: Dict[int, Matrix] = {}
    current_job: int | None = None
    current_rows: Matrix = []

    with path.open("r", encoding="utf-8", errors="replace") as input_file:
        for line_number, raw_line in enumerate(input_file, start=1):
            line = raw_line.strip()
            if not line:
                continue

            begin_match = BEGIN_RE.match(line)
            if begin_match:
                if current_job is not None:
                    raise ValueError(
                        f"Line {line_number}: MATRIX_BEGIN appeared before the previous block ended"
                    )
                job_number = int(begin_match.group(1))
                if not 1 <= job_number <= JOB_COUNT:
                    raise ValueError(f"Line {line_number}: invalid job number {job_number}")
                current_job = job_number - 1
                current_rows = []
                continue

            end_match = END_RE.match(line)
            if end_match:
                if current_job is None:
                    raise ValueError(f"Line {line_number}: MATRIX_END without MATRIX_BEGIN")
                end_job = int(end_match.group(1)) - 1
                if end_job != current_job:
                    raise ValueError(
                        f"Line {line_number}: block began as Job {current_job + 1} "
                        f"but ended as Job {end_job + 1}"
                    )
                if len(current_rows) != M:
                    raise ValueError(
                        f"Job {current_job + 1}: found {len(current_rows)} rows; expected {M}"
                    )
                matrices[current_job] = current_rows
                current_job = None
                current_rows = []
                continue

            if current_job is None:
      
                continue

            values = [int(token) for token in INTEGER_RE.findall(line)]
            if len(values) != N:
                raise ValueError(
                    f"Line {line_number}, Job {current_job + 1}, row {len(current_rows)}: "
                    f"found {len(values)} values; expected {N}"
                )
            if any(value < -128 or value > 127 for value in values):
                raise ValueError(
                    f"Line {line_number}: matrix contains a value outside signed INT8 range"
                )
            current_rows.append(values)

    if current_job is not None:
        raise ValueError(f"Job {current_job + 1}: missing MATRIX_END line")
    if not matrices:
        raise ValueError(
            "No matrix block found. Copy from MATRIX_BEGIN JOB=... through MATRIX_END JOB=..."
        )

    return matrices


def compare_matrix(job_id: int, actual: Matrix) -> Tuple[int, int]:
    a, b = build_input_matrices(job_id)
    expected = software_gemm(a, b)

    match_count = 0
    mismatch_count = 0
    mismatch_details: List[str] = []

    for row in range(M):
        for col in range(N):
            software_value = expected[row][col]
            console_value = actual[row][col]

            if software_value == console_value:
                match_count += 1
            else:
                mismatch_count += 1
                if len(mismatch_details) < MAX_MISMATCH_DETAILS:
                    mismatch_details.append(
                        f"    row={row:2d}, col={col:2d}: "
                        f"software={software_value:4d}, console={console_value:4d}"
                    )

    status = "PASS" if mismatch_count == 0 else "FAIL"
    print(f"JOB {job_id + 1}: {status}")
    print(f"  Total elements : {M * N}")
    print(f"  Match          : {match_count}")
    print(f"  Mismatch       : {mismatch_count}")

    if mismatch_details:
        print(f"  First {len(mismatch_details)} mismatch(es):")
        print("\n".join(mismatch_details))

    return match_count, mismatch_count


def main() -> int:
    if not RESULT_FILE.is_file():
        print(f"ERROR: cannot find {RESULT_FILE.name}")
        print(f"Place {RESULT_FILE.name} in the same folder as this Python file.")
        return 2

    try:
        matrices = read_copied_matrices(RESULT_FILE)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}")
        return 2

    total_match = 0
    total_mismatch = 0

    print(f"Input file: {RESULT_FILE}")
    print(f"Detected jobs: {', '.join(str(job + 1) for job in sorted(matrices))}")
    print("=" * 64)

    for job_id in sorted(matrices):
        match_count, mismatch_count = compare_matrix(job_id, matrices[job_id])
        total_match += match_count
        total_mismatch += mismatch_count
        print("-" * 64)

    overall_status = "PASS" if total_mismatch == 0 else "FAIL"
    print(f"TOTAL MATCH    : {total_match}")
    print(f"TOTAL MISMATCH : {total_mismatch}")
    print(f"OVERALL        : {overall_status}")

    return 0 if total_mismatch == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

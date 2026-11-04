#!/bin/bash
# Harden one ProcessingElement with the gemm_pe configuration of the current flow
# (designs/gemm_pe, identical to openlane/designs/gemm_pe of the repo; PE.v identical to
# rtl_asic/PE.v), OpenLane 1.0.2 non-interactive flow, tag paper_pe.
cd ${OL}
exec /usr/bin/time -f "PROBE wall %e s, maxrss %M kB" docker run --rm --name pe_harden \
  -v ${OL}:/openlane -v ${OL}/designs:/openlane/install -v ~:~ \
  -v ${PDK_ROOT}:${PDK_ROOT} -e PDK_ROOT=${PDK_ROOT} -e PDK=sky130A -e ROUTING_CORES=8 \
  --user 1000:1000 --memory=10g --memory-swap=40g -w /openlane \
  ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64 \
  sh -c "./flow.tcl -design gemm_pe -tag paper_pe -overwrite"

function reservedRE = compute_reserved_re_for_fixed_tbs(carrier, dmrsCfg)
%COMPUTE_RESERVED_RE_FOR_FIXED_TBS Compute REs to reserve for fixed-TBS mode.
%
%   reservedRE = COMPUTE_RESERVED_RE_FOR_FIXED_TBS(carrier, dmrsCfg)
%
%   When using sparse DMRS patterns with fixed TBS, we need to ensure the
%   same number of data REs as the NR baseline. This function computes which
%   REs are used by the NR baseline DMRS but NOT by the sparse pattern.
%   These REs are then marked as ReservedRE in the PDSCH config, preventing
%   them from being used for data. This ensures identical TBS, G, and code
%   rate across all patterns, isolating only the channel estimation quality.
%
%   carrier  — pre6GCarrierConfig object (already configured)
%   dmrsCfg  — struct from dmrs_config() for the sparse pattern
%
%   reservedRE — 0-based RE indices within the BWP to reserve

    % Build NR baseline PDSCH config to get its DMRS indices
    pdsch_baseline = pre6GPDSCHConfig;
    pdsch_baseline.PRBSet = 0:carrier.NSizeGrid-1;
    pdsch_baseline.SymbolAllocation = [0, carrier.SymbolsPerSlot];
    pdsch_baseline.NumLayers = 1;  % Single layer for index comparison
    pdsch_baseline.DMRS.DMRSConfigurationType = 1;
    pdsch_baseline.DMRS.DMRSLength = 1;
    pdsch_baseline.DMRS.DMRSAdditionalPosition = 1;
    pdsch_baseline.DMRS.DMRSTypeAPosition = 2;
    pdsch_baseline.DMRS.NumCDMGroupsWithoutData = 2;
    pdsch_baseline.DMRS.DMRSPortSet = 0;

    % Build sparse PDSCH config to get its DMRS indices
    pdsch_sparse = pre6GPDSCHConfig;
    pdsch_sparse.PRBSet = 0:carrier.NSizeGrid-1;
    pdsch_sparse.SymbolAllocation = [0, carrier.SymbolsPerSlot];
    pdsch_sparse.NumLayers = 1;
    pdsch_sparse.DMRS.DMRSConfigurationType = dmrsCfg.DMRSConfigurationType;
    pdsch_sparse.DMRS.DMRSLength = dmrsCfg.DMRSLength;
    pdsch_sparse.DMRS.DMRSAdditionalPosition = dmrsCfg.DMRSAdditionalPosition;
    pdsch_sparse.DMRS.DMRSTypeAPosition = dmrsCfg.DMRSTypeAPosition;
    pdsch_sparse.DMRS.NumCDMGroupsWithoutData = dmrsCfg.NumCDMGroupsWithoutData;
    pdsch_sparse.DMRS.DMRSPortSet = dmrsCfg.DMRSPortSet;
    if ~isempty(dmrsCfg.CustomSymbolSet)
        pdsch_sparse.DMRS.CustomSymbolSet = dmrsCfg.CustomSymbolSet;
    end

    % Get DMRS indices for both (1-based linear indices in carrier grid)
    dmrsInd_baseline = hpre6GPDSCHDMRSIndices(carrier, pdsch_baseline);
    dmrsInd_sparse = hpre6GPDSCHDMRSIndices(carrier, pdsch_sparse);

    % Also get the "not used for data" REs in each config.
    % In NR, DMRS symbols occupy certain REs, and additionally
    % NumCDMGroupsWithoutData CDM groups are excluded from data even if 
    % they don't carry DMRS for this port. We need ALL REs that are
    % excluded from data in the baseline but NOT excluded in the sparse config.

    % Get PDSCH data indices for both configs
    pdschInd_baseline = hpre6GPDSCHIndices(carrier, pdsch_baseline);
    pdschInd_sparse = hpre6GPDSCHIndices(carrier, pdsch_sparse);

    % REs that are data in sparse but NOT data in baseline = the freed REs
    % These are the ones we need to reserve to equalize the data RE count
    freedRE_linear = setdiff(pdschInd_sparse, pdschInd_baseline);

    % Convert from 1-based linear indices to 0-based for ReservedRE property
    % ReservedRE expects 0-based linear indices within the BWP
    reservedRE = freedRE_linear - 1;

    % Diagnostic output
    nBaseline = numel(pdschInd_baseline);
    nSparse = numel(pdschInd_sparse);
    nReserved = numel(reservedRE);
    nAfterReserve = nSparse - nReserved;
    
    fprintf('  Fixed TBS: baseline data REs=%d, sparse data REs=%d, reserving %d REs, result=%d data REs\n', ...
        nBaseline, nSparse, nReserved, nAfterReserve);
end

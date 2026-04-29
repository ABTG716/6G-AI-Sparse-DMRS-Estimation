function cfg = evm_pdsch_lls(varargin)
%EVM_PDSCH_LLS RAN1#124 agreed PDSCH LLS evaluation methodology parameters.
%
%   cfg = EVM_PDSCH_LLS() returns default config (4 GHz, CDL-C, 100ns DS)
%   cfg = EVM_PDSCH_LLS('CarrierFreq',0.7e9,'DelayProfile','CDL-A') overrides
%
%   All parameters here come from the Chair Notes of RAN1#124, Gothenburg,
%   Feb 2026 — specifically the "Agreement: Study PDSCH and RS for PDSCH 
%   based on the following LLS EVM assumptions" table.
%
%   Source: Chair_notes_RAN1_124_-_eom.docx, lines ~27500-27600

    p = inputParser;
    
    %% --- Carrier & Numerology (Chair Notes Agreement) ---
    % Agreed: 0.7 GHz FDD, 2 GHz FDD, 4 GHz TDD, 7 GHz TDD, 30 GHz TDD
    addParameter(p, 'CarrierFreq', 4e9);       % Hz
    % Agreed SCS: 15 kHz for 0.7/2 GHz, 30 kHz for 4/7 GHz, 120 kHz for 30 GHz
    addParameter(p, 'SubcarrierSpacing', 30);   % kHz
    
    %% --- Waveform ---
    % Agreed: CP-OFDM
    addParameter(p, 'Waveform', 'CP-OFDM');
    
    %% --- Channel Model (LLS specific) ---
    % Agreed: CDL-A/C/D in TR 38.901
    addParameter(p, 'DelayProfile', 'CDL-C');
    % Agreed delay spread: 30, 100, 300, 1000 ns (optional)
    addParameter(p, 'DelaySpread', 100e-9);     % seconds
    
    %% --- System Bandwidth ---
    % Agreed: 20 MHz, 100 MHz, others not precluded
    addParameter(p, 'BandwidthMHz', 20);
    
    %% --- PRG Size ---
    % Agreed: 2 RBs, 4 RBs and wideband as start point for evaluation
    addParameter(p, 'PRGBundleSize', []);       % [] = wideband
    
    %% --- UE Speed ---
    % Agreed: 3, 30, 120, 350, 500 km/h
    addParameter(p, 'UESpeed_kmh', 30);
    
    %% --- Antenna Configuration ---
    % Agreed: Align with SLS (from Chair Notes antenna config tables)
    % Starting with simplest: 4 TXRUs, 32 AEs at ~4 GHz
    % (M,N,P,Mg,Ng,Mp,Np) = (8,2,2,1,1;1,2), (dH,dV)=(0.5,0.8)
    addParameter(p, 'NTxAnts', 4);
    addParameter(p, 'NRxAnts', 2);
    addParameter(p, 'TxArrayConfig', [8 2 2 1 1 1 2]);  % [M N P Mg Ng Mp Np]
    addParameter(p, 'TxAntSpacing', [0.5 0.8]);          % [dH dV] in wavelengths
    addParameter(p, 'RxArrayConfig', [1 1 2 1 1 1 1]);   % UE antenna (from AI 10.1)
    addParameter(p, 'RxAntSpacing', [0.5 0.5]);
    
    %% --- Receiver ---
    % Agreed: MMSE-IRC (baseline), R-ML (optional)
    addParameter(p, 'Receiver', 'MMSE-IRC');
    
    %% --- Channel Estimation ---
    % Agreed: Realistic
    addParameter(p, 'PerfectChannelEstimation', false);
    
    %% --- MIMO ---
    % Agreed: Reported by companies
    addParameter(p, 'NumLayers', 1);
    addParameter(p, 'MIMOScheme', 'SU-MIMO');
    
    %% --- MU-MIMO Interference ---
    % Agreed: Rel-18 DMRS enhancement model can be reused
    addParameter(p, 'MUMIMOInterference', false);
    addParameter(p, 'MUMIMOInterfModel', 'Rel18');  % companies report Alt
    
    %% --- Link Adaptation & HARQ ---
    % Agreed: AMC or fixed MCS
    addParameter(p, 'LinkAdaptation', 'FixedMCS');
    addParameter(p, 'Modulation', '16QAM');       % QPSK/16QAM/64QAM/256QAM
    addParameter(p, 'TargetCodeRate', 490/1024);
    addParameter(p, 'EnableHARQ', true);
    
    %% --- Fixed TBS Mode ---
    % When true, sparse DMRS patterns are forced to use the same TBS as the
    % NR baseline by marking freed DMRS REs as reserved (ReservedRE).
    % This isolates channel estimation quality from overhead gain.
    addParameter(p, 'FixedTBS', false);
    
    %% --- Phase Errors (for 4 TXRUs with uncalibrated antennas) ---
    % Agreed: Independent random phase offset U[0,2pi] between Tx ports
    addParameter(p, 'PhaseErrorModel', 'none');  % 'none' or 'random_uniform'
    
    %% --- Performance Metrics ---
    % Agreed: BLER, SE, Throughput
    addParameter(p, 'Metrics', {'BLER','SE','Throughput','MSE'});
    
    %% --- Simulation Control ---
    addParameter(p, 'NFrames', 10);
    addParameter(p, 'SNRdB', -5:2:25);
    addParameter(p, 'EnableParallelism', true);
    
    %% --- Channel Parameter Estimation ---
    % Agreed: Companies to report (delay spread, Doppler, delay, SNR)
    addParameter(p, 'ChannelParamEstimation', 'none');
    
    parse(p, varargin{:});
    cfg = p.Results;
    
    %% --- Derived Parameters ---
    cfg = deriveNumerology(cfg);
    cfg = deriveAntennaConfig(cfg);
end

function cfg = deriveNumerology(cfg)
    % Map carrier frequency to agreed SCS if not explicitly set
    freqGHz = cfg.CarrierFreq / 1e9;
    
    % Auto-set SCS based on agreed mapping
    if freqGHz <= 2
        cfg.AgreedSCS = 15;     % 15 kHz for FDD / 0.7-2 GHz
        cfg.DuplexMode = 'FDD';
    elseif freqGHz <= 7
        cfg.AgreedSCS = 30;     % 30 kHz for TDD / 4-7 GHz
        cfg.DuplexMode = 'TDD';
    else
        cfg.AgreedSCS = 120;    % 120 kHz for TDD / 30 GHz
        cfg.DuplexMode = 'TDD';
    end
    
    % Number of RBs from TS 38.104 Table 5.3.2-1 (NR standard values)
    % For 6G (>275 RBs or non-standard BW), fall back to calculation
    nrbTable = nrb_lookup(cfg.BandwidthMHz, cfg.SubcarrierSpacing);
    if ~isempty(nrbTable)
        cfg.NSizeGrid = nrbTable;
    else
        % Fallback for non-standard BW: conservative estimate
        scs_kHz = cfg.SubcarrierSpacing;
        bw_Hz = cfg.BandwidthMHz * 1e6;
        cfg.NSizeGrid = floor(bw_Hz / (scs_kHz * 1e3 * 12)) - 3;
    end
    
    % Maximum Doppler shift from UE speed
    c = 3e8;  % speed of light
    cfg.MaxDopplerShift = (cfg.UESpeed_kmh / 3.6) * cfg.CarrierFreq / c;
end

function cfg = deriveAntennaConfig(cfg)
    % Validate antenna config against number of Tx/Rx antennas
    % TxArrayConfig = [M N P Mg Ng Mp Np]
    if numel(cfg.TxArrayConfig) == 7
        M  = cfg.TxArrayConfig(1);
        N  = cfg.TxArrayConfig(2);
        P  = cfg.TxArrayConfig(3);
        Mg = cfg.TxArrayConfig(4);
        Ng = cfg.TxArrayConfig(5);
        Mp = cfg.TxArrayConfig(6);
        Np = cfg.TxArrayConfig(7);
        cfg.NumTxAEs = M * N * P * Mg * Ng;  % Total antenna elements
        cfg.NumTxRUs = Mp * Np * P;           % Total TXRUs
    end
end

function nrb = nrb_lookup(bwMHz, scsKHz)
%NRB_LOOKUP NR standard RB count from TS 38.104 Table 5.3.2-1.
%   Returns [] if the BW/SCS combination is not in the standard table
%   (e.g., for 6G extended configurations).

    % FR1: BW (MHz) → NRB for each SCS
    %        BW:   5   10   15   20   25   30   40   50   60   70   80   90  100
    fr1_15 = [  25   52   79  106  133  160  216  270    0    0    0    0    0];
    fr1_30 = [  11   24   38   51   65   78  106  133  162  189  217  245  273];
    fr1_60 = [   0   11   18   24   31   38   51   65   79   93  107  121  135];

    bws_fr1 = [5 10 15 20 25 30 40 50 60 70 80 90 100];

    % FR2: BW (MHz) → NRB
    %        BW:  50  100  200  400
    fr2_60  = [ 66  132  264    0];
    fr2_120 = [ 32   66  132  264];

    bws_fr2 = [50 100 200 400];

    nrb = [];

    switch scsKHz
        case 15
            idx = find(bws_fr1 == bwMHz, 1);
            if ~isempty(idx) && fr1_15(idx) > 0
                nrb = fr1_15(idx);
            end
        case 30
            idx = find(bws_fr1 == bwMHz, 1);
            if ~isempty(idx) && fr1_30(idx) > 0
                nrb = fr1_30(idx);
            end
        case 60
            idx = find(bws_fr1 == bwMHz, 1);
            if ~isempty(idx) && fr1_60(idx) > 0
                nrb = fr1_60(idx);
            else
                idx = find(bws_fr2 == bwMHz, 1);
                if ~isempty(idx) && fr2_60(idx) > 0
                    nrb = fr2_60(idx);
                end
            end
        case 120
            idx = find(bws_fr2 == bwMHz, 1);
            if ~isempty(idx) && fr2_120(idx) > 0
                nrb = fr2_120(idx);
            end
    end
end

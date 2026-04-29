clc; clear;

%% Simulation Parameters
SNRdB = 10;
totalNoSlots = 20;
perfectEstimation = false;
rng("default");

%% Carrier
carrier = nrCarrierConfig;
carrier.SubcarrierSpacing = 30;
carrier.NSizeGrid = 8;   % 8 PRBs
carrier.NStartGrid = 0;
carrier.CyclicPrefix = "Normal";

%% PDSCH
pdsch = nrPDSCHConfig;
pdsch.Modulation = "QPSK";
pdsch.NumLayers = 1;
pdsch.PRBSet = 0:7;
pdsch.SymbolAllocation = [0 14];

pdsch.DMRS.DMRSTypeAPosition = 2;
pdsch.DMRS.DMRSLength = 1;
pdsch.DMRS.DMRSAdditionalPosition = 1;
pdsch.DMRS.DMRSConfigurationType = 1;
pdsch.DMRS.NumCDMGroupsWithoutData = 2;   % Comb-2 density


%% Coding Rate
if pdsch.NumCodewords == 1
    codeRate = 490/1024;
else
    codeRate = [490 490]./1024;
end

%% DL-SCH Encoder/Decoder (No HARQ)
encodeDLSCH = nrDLSCH;
encodeDLSCH.MultipleHARQProcesses = false;
encodeDLSCH.TargetCodeRate = codeRate;

decodeDLSCH = nrDLSCHDecoder;
decodeDLSCH.MultipleHARQProcesses = false;
decodeDLSCH.TargetCodeRate = codeRate;
decodeDLSCH.LDPCDecodingAlgorithm = "Normalized min-sum";
decodeDLSCH.MaximumLDPCIterationCount = 6;

%% MIMO
nTxAnts = 4;
nRxAnts = 1;

%% Channel
channel = nrCDLChannel;
channel.DelayProfile = "CDL-A";
channel.DelaySpread = 300e-9;

channel.TransmitAntennaArray.Size = [nTxAnts 1 1 1 1];
channel.ReceiveAntennaArray.Size  = [nRxAnts 1 1 1 1];

fc = 4e9;
v_kmph = 5;
v = v_kmph * 1000/3600;     % m/s
c = 3e8;

fd = (v/c) * fc;

channel.MaximumDopplerShift = fd;


ofdmInfo = nrOFDMInfo(carrier);
channel.SampleRate = ofdmInfo.SampleRate;
channel.ChannelResponseOutput = 'ofdm-response';

%% Initial Precoding
offset = 0;
newPrecodingWeight = eye(pdsch.NumLayers,nTxAnts);

numSC = carrier.NSizeGrid * 12;
numSym = carrier.SymbolsPerSlot;

inputDataset  = zeros(numSC, numSym, 2, totalNoSlots);
targetDataset = zeros(numSC, numSym, 2, totalNoSlots);


%% Slot Loop
for nSlot = 0:totalNoSlots-1

    carrier.NSlot = nSlot;

    [pdschIndices,pdschInfo] = nrPDSCHIndices(carrier,pdsch);

    trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,...
        numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,0);

    %% Always New Transport Block (No HARQ)
    for cwIdx = 1:pdsch.NumCodewords
        trBlk = randi([0 1],trBlkSizes(cwIdx),1);
        setTransportBlock(encodeDLSCH,trBlk,cwIdx-1);
    end

    rv = 0;

    codedTrBlock = encodeDLSCH(pdsch.Modulation,...
    pdsch.NumLayers,pdschInfo.G,rv);


    %% PDSCH Modulation
    pdschSymbols = nrPDSCH(carrier,pdsch,codedTrBlock);

    precodingWeights = newPrecodingWeight;
    pdschSymbolsPrecoded = pdschSymbols * precodingWeights;

    %% DMRS
    dmrsSymbols = nrPDSCHDMRS(carrier,pdsch);
    dmrsIndices = nrPDSCHDMRSIndices(carrier,pdsch);

    pdschGrid = nrResourceGrid(carrier,nTxAnts);

    [~,pdschAntIndices] = nrExtractResources(pdschIndices,pdschGrid);
    pdschGrid(pdschAntIndices) = pdschSymbolsPrecoded;

    for p = 1:size(dmrsSymbols,2)
        [~,dmrsAntIndices] = nrExtractResources(dmrsIndices(:,p),pdschGrid);
        pdschGrid(dmrsAntIndices) = ...
            pdschGrid(dmrsAntIndices) + ...
            dmrsSymbols(:,p)*precodingWeights(p,:);
    end

    %% OFDM
    [txWaveform,waveformInfo] = nrOFDMModulate(carrier,pdschGrid);

    chInfo = info(channel);
    txWaveform = [txWaveform; ...
        zeros(chInfo.MaximumChannelDelay,size(txWaveform,2))];

    %% Channel
    [rxWaveform,ofdmChannelResponse,timingOffset] = ...
        channel(txWaveform,carrier);

    [noise,nVar] = generateAWGN(SNRdB,nRxAnts,...
        waveformInfo.Nfft,size(rxWaveform));

    rxWaveform = rxWaveform + noise;

    Hant = squeeze(ofdmChannelResponse);   % [SC × Sym × Tx]
    w = precodingWeights.';                % [Tx × 1]

    perfectCh = zeros(size(Hant,1), size(Hant,2));

    for tx = 1:nTxAnts
        perfectCh = perfectCh + Hant(:,:,tx) * w(tx);
    end


    targetDataset(:,:,1,nSlot+1) = real(perfectCh);
    targetDataset(:,:,2,nSlot+1) = imag(perfectCh);

    %% Timing
    if perfectEstimation
        offset = timingOffset;
    else
        [t,mag] = nrTimingEstimate(carrier,rxWaveform,...
            dmrsIndices,dmrsSymbols);
        offset = hSkipWeakTimingOffset(offset,t,mag);
    end

    rxWaveform = rxWaveform(1+offset:end,:);

    %% OFDM Demod
    rxGrid = nrOFDMDemodulate(carrier,rxWaveform);

    %% Channel Estimation
    if perfectEstimation
        estChGridAnts = ofdmChannelResponse;
        noiseEst = nVar;
        newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,...
            pdsch.NumLayers,estChGridAnts);
        estChGridLayers = precodeChannelEstimate(estChGridAnts,...
            precodingWeights.');
    else
        [estChGridLayers,noiseEst] = nrChannelEstimate(carrier,...
            rxGrid,dmrsIndices,dmrsSymbols,...
            'CDMLengths',pdsch.DMRS.CDMLengths);

        estChGridAnts = precodeChannelEstimate(estChGridLayers,...
            conj(precodingWeights));

        newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,...
            pdsch.NumLayers,estChGridAnts);
    end

    sparseGrid = zeros(size(estChGridLayers(:,:,1,1)));
    
    layerCh = squeeze(estChGridLayers(:,:,1,1));   % SC × Sym
    
    sparseGrid = zeros(size(layerCh));

    dmrsMask = false(size(layerCh));
    dmrsMask(dmrsIndices) = true;

    sparseGrid(dmrsMask) = layerCh(dmrsMask);
    inputDataset(:,:,1,nSlot+1) = real(sparseGrid);
    inputDataset(:,:,2,nSlot+1) = imag(sparseGrid);


    %% Equalization
    [pdschRx,pdschHest] = nrExtractResources(pdschIndices,...
        rxGrid,estChGridLayers);

    [pdschEq,csi] = nrEqualizeMMSE(pdschRx,pdschHest,noiseEst);

    %% Decode
    [dlschLLRs,rxSymbols] = nrPDSCHDecode(carrier,...
        pdsch,pdschEq,noiseEst);

    csi = nrLayerDemap(csi);
    for cwIdx = 1:pdsch.NumCodewords
        Qm = length(dlschLLRs{cwIdx})/length(rxSymbols{cwIdx});
        csi{cwIdx} = repmat(csi{cwIdx}.',Qm,1);
        dlschLLRs{cwIdx} = dlschLLRs{cwIdx} .* csi{cwIdx}(:);
    end

    decodeDLSCH.TransportBlockLength = trBlkSizes;

    [~,blkerr] = decodeDLSCH(dlschLLRs,...
    pdsch.Modulation,pdsch.NumLayers,rv);


    disp("Slot "+nSlot+" Block Error = "+any(blkerr));

end

save('TF_sparse_dmrs_dataset.mat','inputDataset','targetDataset','-v7.3');

function [noise,nVar] = generateAWGN(SNRdB,nRxAnts,Nfft,sizeRxWaveform)

    SNR = 10^(SNRdB/10);
    N0 = 1/sqrt(nRxAnts*double(Nfft)*SNR);

    noise = N0*randn(sizeRxWaveform,"like",1i);

    nVar = N0^2*double(Nfft);

end
function estChannelGrid = precodeChannelEstimate(estChannelGrid,W)

    K = size(estChannelGrid,1);
    L = size(estChannelGrid,2);
    R = size(estChannelGrid,3);

    estChannelGrid = reshape(estChannelGrid,K*L*R,[]);
    estChannelGrid = estChannelGrid * W;
    estChannelGrid = reshape(estChannelGrid,K,L,R,[]);

end
function wtx = getPrecodingMatrix(PRBSet,NLayers,hestGrid)

    allocSc = (1:12)' + 12*PRBSet(:).';
    allocSc = allocSc(:);

    [~,~,R,P] = size(hestGrid);
    estAllocGrid = hestGrid(allocSc,:,:,:);

    Hest = permute(mean(reshape(estAllocGrid,[],R,P)),[2 3 1]);
    [~,~,V] = svd(Hest);

    wtx = V(:,1:NLayers).';
    wtx = wtx/sqrt(NLayers);

end

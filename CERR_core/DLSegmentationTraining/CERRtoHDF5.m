function errC = CERRtoHDF5(CERRdir,HDF5dir,dataSplitV,strListC,userOptS)
% CERRtoHDF5.m
%
% Script to export scan and mask files in HDF5 format, split into training,
% validation, and test datasets.
% Mask: Numerical labels are assigned following the order of
% structure names input (strListC). Background voxels are assigned label=0.
%
%
% AI 3/12/19
%--------------------------------------------------------------------------
%INPUTS:
% CERRdir       : Path to generated CERR files
% HDF5dir       : Path to generated HDF5 files
% dataSplitV    : Train/Val/Test split fraction
% strListC      : List of structures to export
% userOptS      : Options for resampling, cropping, resizing etc.
%                 See sample file: CERR_core/DLSegmentationTraining/sample_train_params.json                
%--------------------------------------------------------------------------
%AI 9/3/19 Added resampling option

%% Get user inputs
outSizeV = userOptS.outSize;
resizeMethod = userOptS.resizeMethod;
cropS = userOptS.crop;
resampleS = userOptS.resample;

%% Get data split
[trainIdxV,valIdxV,testIdxV] = randSplitData(CERRdir,dataSplitV);

%% Batch convert CERR to HDF5
fprintf('\nConverting data to HDF5...\n');

%Label key
labelKeyS = struct();
for n = 1:length(strListC)
    labelKeyS.(strListC{n}) = n;
end

dirS = dir(fullfile(CERRdir,filesep,'*.mat'));
labelV = 1:length(strListC);

resC = cell(1,length(dirS));
errC = {};
%Loop over CERR files
for planNum = 1:length(dirS)
    
    try
        
        %Load file
        fprintf('\nProcessing pt %d of %d...\n',planNum,length(dirS));
        [~,ptName,~] = fileparts(dirS(planNum).name);
        fileNam = fullfile(CERRdir,dirS(planNum).name);
        planC = loadPlanC(fileNam, tempdir);
        planC = quality_assure_planC(fileNam,planC);
        indexS = planC{end};
        
        %Identify available structures
        allStrC = {planC{indexS.structures}.structureName};
        strNotAvailableV = ~ismember(lower(strListC),lower(allStrC)); %Case-insensitive
        if any(strNotAvailableV)
            warning(['Skipping missing structures: ',strjoin(strListC(strNotAvailableV),',')]);
        end
        exportStrC = strListC(~strNotAvailableV);
        
        if ~isempty(exportStrC) || ismember(planNum,testIdxV)
            
            exportLabelV = labelV(~strNotAvailableV);
            
            
            %Get structure ID and assoc scan
            strIdxV = nan(length(exportStrC),1);
            for strNum = 1:length(exportStrC)
                
                currentLabelName = exportStrC{strNum};
                strIdxV(strNum) = getMatchingIndex(currentLabelName,allStrC,'exact');
                
            end
            
            %Extract scan arrays
            if isempty(exportStrC) && ismember(planNum,testIdxV)
                scanNumV = 1; %Assume scan 1
            else
                scanNumV = unique(getStructureAssociatedScan(strIdxV,planC));
            end
            
            UIDc = {planC{indexS.structures}.assocScanUID};
            resM = nan(length(scanNumV),3);
            
            for scanIdx = 1:length(scanNumV)
                
                scan3M = double(getScanArray(scanNumV(scanIdx),planC));
                CTOffset = planC{indexS.scan}(scanNumV(scanIdx)).scanInfo(1).CTOffset;
                scan3M = scan3M - CTOffset;
                
                %Extract masks
                if isempty(exportStrC) && ismember(planNum,testIdxV)
                    mask3M = [];
                    validStrIdxV = [];
                else
                    mask3M = zeros(size(scan3M));
                    assocStrIdxV = strcmpi(planC{indexS.scan}(scanNumV(scanIdx)).scanUID,UIDc);
                    validStrIdxV = ismember(strIdxV,find(assocStrIdxV));
                    validExportLabelV = exportLabelV(validStrIdxV);
                    validStrIdxV = strIdxV(validStrIdxV);
                end
                for strNum = 1:length(validStrIdxV)
                    
                    strIdx = validStrIdxV(strNum);
                    
                    %Update labels
                    tempMask3M = false(size(mask3M));
                    [rasterSegM, planC] = getRasterSegments(strIdx,planC);
                    [maskSlicesM, uniqueSlices] = rasterToMask(rasterSegM, scanNumV(scanIdx), planC);
                    tempMask3M(:,:,uniqueSlices) = maskSlicesM;
                    
                    mask3M(tempMask3M) = validExportLabelV(strNum);
                    
                end
                
                %Resample
                if isfield(userOptS,'resample')
                    
                    % Get the new x,y,z grid
                    [xValsV, yValsV, zValsV] = getScanXYZVals(planC{indexS.scan}(scanNumV(scanIdx)));
                    if yValsV(1) > yValsV(2)
                        yValsV = fliplr(yValsV);
                    end
                    
                    xValsV = xValsV(1):resampleS.resolutionXCm:(xValsV(end)+10000*eps);
                    yValsV = yValsV(1):resampleS.resolutionYCm:(yValsV(end)+10000*eps);
                    zValsV = zValsV(1):resampleS.resolutionZCm:(zValsV(end)+10000*eps);
                    
                    % Interpolate using sinc sampling
                    numCols = length(xValsV);
                    numRows = length(yValsV);
                    numSlcs = length(zValsV);
                    %Get resampling method
                    
                    if strcmpi(resampleS.interpMethod,'sinc')
                        method = 'lanczos3';
                    end
                    scan3M = imresize3(scan3M,[numRows numCols numSlcs],'method',method);
                    mask3M = imresize3(single(mask3M),[numRows numCols numSlcs],'method',method) > 0.5;
                    
                end
                
                %Pre-processing
                %1. Crop
                [scan3M,mask3M] = cropScanAndMask(planC,scan3M,mask3M,cropS);
                %2. Resize
                [scan3M,mask3M] = resizeScanAndMask(scan3M,mask3M,outSizeV,resizeMethod);
                
                
                
                %Save to HDF5
                if ismember(planNum,trainIdxV)
                    outDir = [HDF5dir,filesep,'Train'];
                elseif ismember(planNum,valIdxV)
                    outDir = [HDF5dir,filesep,'Val'];
                else
                    outDir = [HDF5dir,filesep,'Test'];
                end
                
                uniformScanInfoS = planC{indexS.scan}(scanNumV(scanIdx)).uniformScanInfo;
                resM(scanIdx,:) = [uniformScanInfoS.grid2Units, uniformScanInfoS.grid1Units, uniformScanInfoS.sliceThickness];
                
                for slIdx = 1:size(scan3M,3)
                    %Save data
                    maskM = uint8(mask3M(:,:,slIdx));
                    if ~isempty(maskM)
                        maskFilename = fullfile(outDir,'Masks',[ptName,'_slice',...
                            num2str(slIdx),'.h5']);
                        h5create(maskFilename,'/mask',size(maskM));
                        h5write(maskFilename,'/mask',maskM);
                    end
                    
                    scanM = scan3M(:,:,slIdx);
                    scanFilename = fullfile(outDir,[ptName,'_scan_',...
                        num2str(scanIdx),'_slice',num2str(slIdx),'.h5']);
                    h5create(scanFilename,'/scan1',size(scanM));
                    h5write(scanFilename,'/scan1',scanM);
                end
                
            end
            
            resC{planNum} = resM;
            
        end
        
    catch e
        errC{planNum} =  ['Error processing pt %s. Failed with message: %s',fileNam,e.message];
    end
    
    save([HDF5dir,filesep,'labelKeyS'],'labelKeyS','-v7.3');
    save([HDF5dir,filesep,'resolutionC'],'resC','-v7.3');
    
    %Return error messages if any
    idxC = cellfun(@isempty, errC, 'un', 0);
    idxV = ~[idxC{:}];
    errC = errC(idxV);
    
    fprintf('\nComplete.\n');
    
    
end


function [  ] = urpec( config )
% function [  ] = urpec( config )
% Generates a proximity-effect-corrected .dxf file for electron beam lithography.
% The corrected file is created by deconvolving a point spread function from an input .dxf pattern file.
% The output file has different layers, each of which should receive a different dose.
% This function assumes that one unit in the input pattern file is one
% micron.
%
% Right now this is intended for use with NPGS.
%
% config is an optional struct with the following optional fields:
%
%   dx: spacing in units of microns for the deconvolution. The default is
%   0.01 mcirons
%
%   subfieldSize: size of subfields in fracturing. Default is 50 points. This
%   is necessary for NPGS because the maximum polygon size in designCAD is
%   200 points.
%
%   maxIter: maximum number of iterations for the deconvolution. Default is
%   6.
%
%   dvals: doses corresponding to the layers in the output file. Default is
%   1, 1.1, 1.2, ... , 2.4 in units of the dose to clear.
%   
%   windowVal: smoothing distance for the dose modulation. Units are
%   approximately the grid spacing. Default is 10.
%
% call this function without any arguments, or via
% urpec(struct('dx',0.005, 'subfieldSize',20,'maxIter',6,'dvals',[1:.2:2.4]))
% for example
%
%
% By:
% Adina Ripin aripin@u.rochester.edu
% Elliot Connors econnors@ur.rochester.edu
% John Nichol jnich10@ur.rochester.edu
%
% TODO:
% Add code to make the run file?
% Add support for different pattern file formats?

tic

addpath('dxflib');

debug=0;

if ~exist('config','var')
    config=struct();
end

config = def(config,'dx',.01);   %Grid spacing in microns
config = def(config,'subfieldSize',50);  %subfield size in microns
config = def(config,'maxIter',6);  %max number of iterations for the deconvolution
config = def(config,'dvals',[1:.1:1.9]);  %doses corresponding to output layers, in units of dose to clear
config = def(config,'windowVal',10);  %Smoothing factor for the dose modultion. Default is 10. Units are approximately the grid spacing.


dx = config.dx;
subfieldSize=config.subfieldSize;

fprintf('urpec is running...\n');

%choose and load file
fprintf('Select your dxf file.\n')

dxf2coord_20;

fprintf('dxf CAD file imported.\n')

out = struct;

%splitting each set of points into its own object
object_num=max(lwpolylines(:,1)); % number of polygons in CAD file
shapes = lwpolylines;
objects = cell(1,object_num); % cell array of polygons in CAD file
len = size(shapes,1); % total number of polylines

% populating 'objects' (cell array of polygons in CAD file)
count = 1;
obj_num_ind_start = 1;
for obj = 1:len % loop over each polyline
    c = lwpolylines(obj,1); % c = object number
    if c ~= count
        objects{count} = lwpolylines(obj_num_ind_start:(obj-1), 1:3);
        obj_num_ind_start = obj;
        count = count + 1;
        if count == object_num
            objects{count} = lwpolylines(obj_num_ind_start:(len), 1:3);
        end
    end
end

%grouping objects of the same size together
areas = cell(1, object_num);
for ar = 1:object_num
    curr_obj = objects{ar};
    areas{ar} = polyarea(curr_obj(:,2), curr_obj(:,3));
end

%this part was coded under the assumption that there would be three main
%size groups of objects

% out.largeobj = cell(1, object_num);
% out.medobj = cell(1, object_num);
% out.smallobj = cell(1, object_num);
% out.justmedobj = cell(1, object_num);

lg_med_threshold = 1e2; % if object area > lg_med_threshold then = lg object
med_sm_threshold = 2; % if med_sm_threshold < object area < lg_med_threshold then = med object
% if object < med_sm_threshold then = small object

%currently medium also includes small for code testing

for ar = 1:object_num
    if areas{ar} > lg_med_threshold
        out.largeobj{ar} = objects{ar};
    else
        out.medobj{ar} = objects{ar};
        %medium objects also include small
        if areas{ar} < med_sm_threshold
            out.smallobj{ar} = objects{ar};
        else
            out.justmed{ar} = objects{ar};
        end
    end
end

display(['dxf CAD file analyzed.']);

% EJC: edit to treat large features as medium if nothing below lg/med
% threshold
if isfield(out,'medobj')
    medall = vertcat(out.medobj{1}, out.medobj{2});
    for i = 3:object_num
        medall = vertcat(medall, out.medobj{i});
    end
else
    try
        out.medobj=out.largeobj;
        out.largeobj='to med obj';
        medall = vertcat(out.medobj{1}, out.medobj{2});
        for i=3:object_num
            medall = vertcat(medall, out.medobj{i});
        end
    end
end

medall=vertcat(objects{1},objects{2});
for i = 3:object_num
    medall = vertcat(medall, objects{i});
end

maxX = max(medall(:,2));
maxY = max(medall(:,3));
minX = min(medall(:,2));
minY = min(medall(:,3));

x = minX:dx:maxX;
y = minY:dx:maxY;
[X,Y] = meshgrid(x, y);
[m,n] = size(X);

if isfield(out,'smallobj')
    sm_all = vertcat(out.smallobj{1}, out.smallobj{2});
    for i = 3:object_num
        sm_all = vertcat(sm_all, out.smallobj{i});
    end
end

fprintf(['Creating 2D binary grid spanning medium feature write field (spacing = ', num2str(dx), '). This can take a few minutes...']);
%polygon distribution - creating binary grid of x,y points that are 1 if
%in a polygon or 0 if not

%Make the simulation area bigger to account for proximity effects
padSize=ceil(5/dx).*dx;
padPoints=padSize/dx;
maxX=maxX+padSize;
minX=minX-padSize;
maxY=maxY+padSize;
minY=minY-padSize;

xp = minX:dx:maxX;
yp = minY:dx:maxY;

%make sure the number of points is odd. This is important for deconvolving the psf
if ~mod(length(xp),2)
    maxX=maxX+dx;
end

if ~mod(length(yp),2)
    maxY=maxY+dx;
end

xp = minX:dx:maxX;
yp = minY:dx:maxY;
[XP, YP] = meshgrid(xp, yp);
[mp, np] = size(XP);

totgridpts = length(xp)*length(yp);
polysbin = zeros(size(XP));

% if ~isfield(out, 'medobj')
%     try
%         out.newmedobj = out.largeobj(~cellfun('isempty',out.largeobj));
%     end
% else
%     out.newmedobj = out.medobj(~cellfun('isempty', out.medobj));
% end
out.newmedobj=out.medobj(~cellfun('isempty',out.medobj));
[mm, nm] = size(out.newmedobj);

for ar = 1:length(objects) %EJC 5/5/2018: run time (should) scale ~linearly~ with med/sm object num
    p = objects{ar};
    subpoly = inpolygon(XP, YP, p(:,2), p(:,3));
    %polysbin = or(polysbin, subpoly);
    
    polysbin=polysbin+subpoly;
end

med_field_width_x = maxX-minX;
med_field_width_y = maxY-minY;

sm_field_width_x = 3;%micron
sm_field_width_y = sm_field_width_x;
sm_field_x_ind = round(sm_field_width_x/dx);
sm_field_y_ind = round(sm_field_width_y/dx);

[xpts ypts] = size(polysbin);
sm_x_min = round((ypts/2)-sm_field_x_ind);
sm_x_max = round((ypts/2)+sm_field_x_ind);
sm_y_min = round((xpts/2)-sm_field_y_ind);
sm_y_max = round((xpts/2)+sm_field_y_ind);

fprintf('done analyzing file.\n')

fprintf('Select point spread function file.\n')
load(uigetfile('*PSF*'));

fprintf('Deconvolving psf...');

eta=psf.eta;
alpha=psf.alpha;
beta=psf.beta;
psfRange=psf.range;
descr=psf.descr;

%psf changes definition immediately below
npsf=round(psfRange./dx);
psf=zeros(round(psfRange./dx));
[xpsf ypsf]=meshgrid([-npsf:1:npsf],[-npsf:1:npsf]);
xpsf=xpsf.*dx;
ypsf=ypsf.*dx;
rpsf2=xpsf.^2+ypsf.^2;
psf=1/(1+eta).*(1/(pi*alpha^2).*exp(-rpsf2./alpha.^2)+eta/(pi*beta^2).*exp(-rpsf2./beta.^2));



%Zero pad to at least 10um x 10 um;
%pad in the x direction
xpad=size(polysbin,1)-size(psf,1);
if xpad>0
    psf=padarray(psf,[xpad/2,0],0,'both');
elseif xpad<0
    polysbin=padarray(polysbin,[-xpad/2,0],0,'both');
end

%pad in the y direction
ypad=size(polysbin,2)-size(psf,2);
if ypad>0
    psf=padarray(psf,[0,ypad/2],0,'both');    
elseif ypad<0
    polysbin=padarray(polysbin,[0,-ypad/2],0,'both');
end

%make a window to prevent ringing;
wind=psf.*0;
xwind=(size(psf,1)-1)/2;
ywind=(size(psf,2)-1)/2;
rw=min([xwind,ywind]);
[xw yw]=meshgrid([-xwind:1:xwind],[-ywind:1:ywind]);
wind=exp(-(xw.^2+yw.^2)./(rw/config.windowVal).^2);
wind=wind';

%normalize
psf=psf./sum(psf(:));

dstart=polysbin;
shape=polysbin>0; %1 inside shapes and 0 everywhere else

dose=dstart;
doseNew=shape; %initial guess at dose. Just the dose to clear everywhere

%iterate on convolving the psf, and add the difference between actual dose and desired dose to the programmed dose
for i=1:config.maxIter
    %doseActual=ifft2(fft2(doseNew.*polysbin).*fft2(psf)); %convolve with the point spread function, taking into account places that are dosed twice
    %doseActual=ifft2(fft2(doseNew).*fft2(psf));
    doseActual=ifft2(fft2(doseNew).*fft2(psf).*fftshift(wind)); %use window to avoid ringing

    doseActual=real(fftshift(doseActual));
    doseShape=doseActual.*shape; %total only given to shapes. Excludes area outside shapes. We don't actually care about this.
    
    figure(556); clf;
    subplot(1,2,2);
    imagesc(doseActual);
    title(sprintf('Actual dose. Iteration %d',i));
    
    doseNew=doseNew+(shape-doseShape); %Deonvolution: add the difference between the desired dose and the actual dose to the shape dose.
    subplot(1,2,1);
    imagesc(doseNew);
    title(sprintf('Programmed dose. Iteration %d',i));
    
    drawnow;
end

dd=doseNew;
ss=shape;

doseNew=dd(padPoints+1:end-padPoints,padPoints+1:end-padPoints);
shape=ss(padPoints+1:end-padPoints,padPoints+1:end-padPoints);
mp=size(doseNew,1);
np=size(doseNew,2);
minXExp=minX+padSize;
minYExp=minY+padSize;

fprintf('done.\n')

fprintf('Fracturing...\n')

%I forget why this is needed?
doseNew(doseNew==0)=NaN;
doseNew(doseNew<0)=NaN;

dvals=config.dvals;
nlayers=length(dvals);
dvalsl=dvals-(dvals(2)-dvals(1));
dvalsr=dvals;
layer=[];
figSize=ceil(sqrt(nlayers));
dvalsAct=[];
for i=1:length(dvals);
    fprintf('layer %d...\n',i);
    
    %Compute shot map for each layer
    if i==1
        layer(i).shotMap=doseNew<dvalsr(i).*shape;
        layer(i).dose=dvals(i);
        
    elseif i==length(dvals)
        layer(i).shotMap=doseNew>dvalsl(i).*shape;
        layer(i).dose=dvals(i);
        
    else
        layer(i).shotMap=(doseNew>dvalsl(i)).*(doseNew<dvalsr(i));
        layer(i).dose=(dvalsl(i)+dvalsr(i))/2;
    end
    
    %Compute the actual mean dose in the layer.
    dd=doseNew;
    dd(isnan(dd))=0;
    doseSum= sum(sum(layer(i).shotMap));
    if doseSum>0
        layer(i).meanDose=sum(sum(layer(i).shotMap.*dd))/sum(sum(layer(i).shotMap));
        dvalsAct(i)=layer(i).meanDose;
    else
        layer(i).meanDose=dvals(i);
        dvalsAct(i)=dvals(i);
    end
    
    %break into subfields and find boundaries. This is necessary because
    %designCAD can only handle polygons with less than ~200 points.
    
    subfieldSize = config.subfieldSize;
    
    layer(i).boundaries={};
    count=1;
    
    decrease = 0;
    disp = 0;
    m=1;
    n=1;
    xsubfields=ceil(mp/subfieldSize);
    ysubfields=ceil(np/subfieldSize);
    decrease_sub = 1;
    while (n <= ysubfields)    %change to x subfields for horizontal writing
        %decrease_sub=1;
        m = 1;
        %decrease_sub = 1;
        while (m <= xsubfields) %change to ysubfields for horizontal writing
            %EJC: add decrease_sub factor for halving sub field size when polygons are large
            if decrease
                subfieldSize = round(subfieldSize/decrease_sub);
                decrease = 0;
                disp = 0;
            end
            xsubfields=ceil(mp/subfieldSize);
            ysubfields=ceil(np/subfieldSize);
            if ~disp
                display(['trying subfield size of ' num2str(subfieldSize) '. There are a total of ' num2str(xsubfields*ysubfields) ' subfields...']);
                disp = 1;
            end
            proceed = 0;
            %for n=1:1:ysubfields %m=1:1:xsubfields
            %for m=1:1:xsubfields %n=1:1:ysubfields
            subfield=zeros(mp,np);
            %display(['Trying subfield size: ' num2str(mp/decrease_sub) 'x' num2str(np/decrease_sub)]);
            if (m-1)*subfieldSize+1<min(m*subfieldSize,mp)
                xinds=(m-1)*subfieldSize+1:1:min(m*subfieldSize,mp);
            else
                xinds=(m-1)*subfieldSize+1:1:min(m*subfieldSize,mp);
            end
            if (n-1)*subfieldSize+1 < min(n*subfieldSize,np)
                yinds=(n-1)*subfieldSize+1:1:min(n*subfieldSize,np);
            else
                yinds=(n-1)*subfieldSize+1:1:min(n*subfieldSize,np);
            end
            
            xstart=xinds(1);
            ystart=yinds(1);
            
            %double the size of each shot map to avoid single pixel
            %features.
            xinds=reshape([xinds;xinds],[1 2*length(xinds)]);
            yinds=reshape([yinds;yinds],[1 2*length(yinds)]);
            
            subdata=layer(i).shotMap(xinds,yinds);
            
            if (sum(subdata(:)))>0
                
                [B,L,nn,A]=bwboundaries(subdata);
                
                if debug
                    figure(777); clf; hold on
                    fprintf('Layer %d subfield (%d,%d) \n',i,m,n);
                    for j=1:length(B)
                        try
                            bb=B{j};
                            subplot(1,2,1); hold on;
                            plot(bb(:,2),bb(:,1))
                            axis([0 subfieldSize 0 subfieldSize]);
                            subplot(1,2,2)
                            imagesc(subdata); set(gca,'YDir','norm')
                            axis([0 subfieldSize 0 subfieldSize]);
                        end
                        pause(1)
                        
                    end
                    drawnow;
                    pause(1);
                end
                
                if ~isempty(B)
                    for b=1:length(B)
                        
                        %Find any holes and fix them, and add them to any
                        %enclosing boundaries
                        enclosing_boundaries=find(A(b,:));
                        for k=1:length(enclosing_boundaries)
                            b1=B{enclosing_boundaries(k)};
                            b2=B{b}; %enclosing boundary
                            b1=[b1; b2; b1(end,:)];
                            B{b}=[];
                            B{enclosing_boundaries(k)}=b1;
                        end
                    end
                    
                    %Add boundaries to layer
                    for b=1:length(B)
                        if ~isempty(B{b})
                            
                            %remove unnecessary vertices
                            B{b}=simplify_polygon(B{b});
                            
                            %check for large polygons
                            if size(B{b},1)>200%200
                                fprintf('Large boundaries in layer %d. Halving subfield size and retrying... \n',i);
                                %TODO:if large boundaries, i=i-1,
                                %subfieldSize=subfieldSize/2; and then don't
                                %execute the next lines.
                                decrease = 1;
                                decrease_sub = decrease_sub + 1;
                                proceed = 0;
                                disp = 0;
                                m = 1;
                                n = 1;
                                count = 1;
                                layer(i).boundaries = {};
                                %anybad = 1;
                            elseif ~decrease
                                decrease_sub = 1;
                                proceed = 1;
                            end
                            
                            if proceed
                                layer(i).boundaries(count)={B{b}/2+repmat([xstart,ystart],[size(B{b},1),1])}; %divide by two because we doubled the size of the shot map
                                count=count+1;
                            end
                        end
                        
                        %Break out of looping over boundaries if there are
                        %large boundaries
                        if proceed==0
                            break
                        end
                    end
                end
            else
                proceed = 1;
            end
            if proceed
                m = m+1;
            end
        end
        if proceed
            n = n+1;
        end
    end
    
    
    fprintf('done.\n')
    
    
end
fprintf('Fracturing complete. \n')

%Inspect layers if needed
if debug
    
    i=3;
    figure(777); clf; hold on
    
    maxSize=0
    for j=1:length(layer(i).boundaries)
        bb=layer(i).boundaries{j};
        plot(bb(:,2),bb(:,1))
        
        ms=size(layer(i).boundaries{j},1);
        if ms> maxSize
            maxSize=ms;
        end
    end
    maxSize
    
    figure(778); clf; imagesc(layer(i).shotMap)
    
end

%save the final file
outputFileName=[pathname filename(1:end-4) '_' descr '.dxf'];
fprintf('Exporting to %s...\n',outputFileName);

FID = dxf_open(outputFileName);

ctab={[1 0 0] [0 1 0] [0 0 1] [1 1 0] [1 0 1] [0 1 1] [1 0 0] [0 1 0] [0 0 1] [1 1 0] [1 0 1] [0 1 1] [1 0 0] [0 1 0] [0 0 1] [1 1 0] [1 0 1] [0 1 1]  };

for i=length(dvals):-1:1
    fprintf('Writing layer %d...',i)
    FID=dxf_set(FID,'Color',ctab{i}.*255,'Layer',i); % EJC: ctab{i} to ctab{i}.*255 (3/8/2019)
    for j=1:length(layer(i).boundaries)
        bb=layer(i).boundaries{j};
        X=bb(:,2).*dx+minXExp;
        Y=bb(:,1).*dx+minYExp;
        Z=X.*0;
        dxf_polyline(FID,X,Y,Z);
    end
    fprintf('done.\n')
end

dxf_close(FID);

%Save doses here
doseFileName=[pathname filename(1:end-4) '_' descr '.txt'];

fileID = fopen(doseFileName,'w');
fprintf(fileID,'%3.3f \r\n',dvalsAct);
fclose(fileID);

fprintf('Finished exporting.\n')

rmpath('dxflib');

fprintf('urpec is finished.\n')

toc

end

% Apply a default.
function s=def(s,f,v)
if(~isfield(s,f))
    s=setfield(s,f,v);
end
end


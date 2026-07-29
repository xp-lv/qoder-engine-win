function state = run_inversion_tv_strict(max_iter, mu_init, alpha_tv)
%RUN_INVERSION_TV_STRICT 收紧收敛阈值 + TV正则化 + 最终画图
%   eps_tol=0.02（比默认 0.05 更严格）

if nargin < 1, max_iter = 15; end
if nargin < 2, mu_init = 1.0; end
if nargin < 3, alpha_tv = 0.5; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  TV 正则化反演 - 严格收敛 (alpha_tv=%.2f, eps_tol=0.02)\n', alpha_tv);
fprintf('############################################################\n\n');

%% 初始化
p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[FAIL]\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1','ExternalCurrentDensity',3);
    phys.feature('vec1').set('Je',{'0','0','0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode','1'); catch; end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);

% TV邻居
fprintf('[INV] 构建 TV 邻居列表...\n');
inner_pos = voxel.pos(inner_idx,:);
neighbor_list = cell(N_inner,1);
for vi=1:N_inner
    dists = vecnorm(inner_pos - inner_pos(vi,:),2,2); dists(vi)=inf;
    [~,sort_idx]=sort(dists);
    neighbor_list{vi} = sort_idx(1:min(8,N_inner))';
end

% J_obs
fprintf('[INV] 预计算 J_obs...\n');
voxel.epsilon_r(inner)=5.0; update_epsilon(model,voxel,p);
model.param.set('freq',num2str(p.freq));
try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
sf_obs=extract_scattered(model,grid_meas); lc_obs=lightcone_project(grid_meas,sf_obs,p);
J_obs=lc_obs.J_obs_perp; dOmega=lc_obs.dOmega;
F_obs=sum(dOmega.*sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

% 初值
voxel.epsilon_r(inner)=3.0;

% 迭代
k0_sq=p.k0^2; dV_vec=voxel.dV; mu=mu_init; eps_tol=0.02;
history_F=zeros(max_iter,1); history_mean=zeros(max_iter,1);
history_std=zeros(max_iter,1); history_eps=cell(max_iter,1);
converged=false; final_iter=0;

for iter=1:max_iter
    fprintf('\n[INV] ===== 迭代 %d/%d =====\n', iter, max_iter);
    
    update_epsilon(model,voxel,p);
    [E_total,~,E_gauss]=solve_forward(model,voxel,p);
    sf=extract_scattered(model,grid_meas); lc=lightcone_project(grid_meas,sf,p);
    Delta_J=J_obs-lc.J_obs_perp;
    F_data=sum(dOmega.*sum(abs(Delta_J).^2,2))/F_obs;
    
    eps_now=voxel.epsilon_r(inner);
    history_F(iter)=F_data; history_mean(iter)=mean(eps_now);
    history_std(iter)=std(eps_now); history_eps{iter}=eps_now;
    if iter==1, history_pos=voxel.pos(inner_idx,:); end
    
    fprintf('[INV] F_data=%.6e sqrt(F)=%.4f mean=%.4f std=%.4f range=[%.2f,%.2f]\n', ...
        F_data, sqrt(F_data), mean(eps_now), std(eps_now), min(eps_now), max(eps_now));
    
    if sqrt(F_data)<eps_tol
        fprintf('[INV] ★★★ 收敛！sqrt(F)=%.4f < %.2f ★★★\n', sqrt(F_data), eps_tol);
        converged=true; final_iter=iter; break;
    end
    
    lc.k_vec=p.k0*lc.k_dir; lc.J_obs_perp=J_obs; lc.Delta_J_perp=Delta_J;
    [Js,Ms,source_pos,~]=build_adjoint_source_fullmaxwell(grid_meas,lc,p);
    [lambda,ok_adj,lambda_gauss]=solve_adjoint(model,voxel,p,Js,source_pos,Ms);
    if ~ok_adj, fprintf('[INV] [FAIL]\n'); break; end
    
    % 数据梯度
    g_data=zeros(N_inner,1);
    use_gauss=~isempty(E_gauss)&&~isempty(lambda_gauss)&&size(E_gauss,1)==size(voxel.gauss_pos,1);
    if use_gauss
        gw=voxel.gauss_w;
        for vi=1:N_inner
            gp=(4*(vi-1)+1):(4*vi); gs=0;
            for gpi=1:4, gs=gs+gw(gpi)*real(sum(E_gauss(gp(gpi),:).*lambda_gauss(gp(gpi),:))); end
            g_data(vi)=-k0_sq*dV_vec(inner_idx(vi))*gs;
        end
    else
        for vi=1:N_inner, g_data(vi)=-k0_sq*dV_vec(inner_idx(vi))*real(sum(E_total(vi,:).*lambda(vi,:))); end
    end
    g_data=g_data/F_obs;
    
    % TV梯度
    g_tv=zeros(N_inner,1);
    for vi=1:N_inner
        nb=neighbor_list{vi}; diffs=eps_now(vi)-eps_now(nb);
        g_tv(vi)=sum(diffs./(abs(diffs)+1e-30));
    end
    g_tv=g_tv/2;
    
    % 自适应lambda
    norm_g_data=norm(g_data); norm_g_tv=norm(g_tv);
    if alpha_tv>0&&norm_g_tv>1e-30
        lambda_adapt=alpha_tv*norm_g_data/norm_g_tv;
    else, lambda_adapt=0; end
    g_total=g_data+lambda_adapt*g_tv;
    
    fprintf('[INV] ||g_data||=%.3e ||g_tv||=%.3e λ=%.3e ||g_total||=%.3e\n', ...
        norm_g_data, norm_g_tv, lambda_adapt, norm(g_total));
    
    % 线搜索
    [voxel,mu,accepted,F_new]=linesearch_tv2(voxel,g_total,p,model,grid_meas,J_obs,lc_obs,mu,F_data,inner,inner_idx,N_inner);
    if accepted, fprintf('[INV] LS accept: %.6e -> %.6e\n', F_data, F_new);
    else
        fprintf('[INV] LS reject\n');
        if iter>=3, fprintf('[INV] 连续拒绝，停止\n'); break; end
    end
    final_iter=iter;
end

%% 结果
fprintf('\n############################################################\n');
fprintf('#  反演结果 (alpha_tv=%.2f, eps_tol=0.02)\n', alpha_tv);
fprintf('#  迭代: %d, 收敛: %s\n', final_iter, string(converged));
fprintf('#  终值: mean=%.4f, std=%.4f, range=[%.3f, %.3f]\n', ...
    mean(real(voxel.epsilon_r(inner))),std(real(voxel.epsilon_r(inner))), ...
    min(real(voxel.epsilon_r(inner))),max(real(voxel.epsilon_r(inner))));
fprintf('############################################################\n');
for iter=1:final_iter
    fprintf('  iter %d: F=%.4e sqrt(F)=%.4f mean=%.4f std=%.4f\n', ...
        iter,history_F(iter),sqrt(history_F(iter)),history_mean(iter),history_std(iter));
end

%% 画图：最终 eps_r 3D 对比真值
figure('Position',[50 50 1400 500],'Color','w');

% 子图1: eps_r 3D
subplot(1,3,1);
pos_all=voxel.pos(inner_idx,:);
eps_final=real(voxel.epsilon_r(inner));
scatter3(pos_all(:,1)*1000,pos_all(:,2)*1000,pos_all(:,3)*1000,15,eps_final,'filled');
colorbar; colormap(jet); caxis([2 8]);
title(sprintf('Final eps_r (iter %d)\nmean=%.2f, std=%.2f',final_iter,mean(eps_final),std(eps_final)),'FontSize',9);
xlabel('x[mm]'); ylabel('y[mm]'); zlabel('z[mm]');
axis equal; view(30,25); hold on;
yline(5,'r--','LineWidth',2,'DisplayName','True=5');

% 子图2: eps_r vs x
subplot(1,3,2);
scatter(pos_all(:,1)*1000,eps_final,10,'b','filled'); hold on;
yline(5.0,'r--','LineWidth',2,'Label','True=5');
xlabel('x [mm]'); ylabel('\epsilon_r');
title(sprintf('eps_r vs x\nrange=[%.2f, %.2f]',min(eps_final),max(eps_final)),'FontSize',9);
ylim([2 10]); grid on;

% 子图3: 残差收敛曲线
subplot(1,3,3);
plot(1:final_iter, sqrt(history_F(1:final_iter)),'b-o','LineWidth',2); hold on;
yline(0.02,'r--','LineWidth',1,'Label','tol=0.02');
yline(0.05,'k:','LineWidth',1,'Label','old tol=0.05');
xlabel('iteration'); ylabel('sqrt(F_data)');
title('Convergence','FontSize',9);
grid on;

saveas(gcf, fullfile('data','results','inversion_tv_strict_final.png'));
fprintf('\n[INV] 图片已保存: data/results/inversion_tv_strict_final.png\n');

state=struct('converged',converged,'iteration',final_iter,...
    'history_F',history_F(1:final_iter),'history_mean',history_mean(1:final_iter),...
    'history_std',history_std(1:final_iter),'eps_final',eps_final,'pos',pos_all);
save(fullfile(p.dir_result,'inversion_tv_strict.mat'),'state');
fprintf('[INV] 结果已保存\n');

try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end
end

function [voxel,mu_next,accepted,F_new]=linesearch_tv2(voxel,g,p,model,grid_meas,J_obs,lc_obs,mu_init,F_old,inner,inner_idx,N_inner)
eps_old=voxel.epsilon_r(inner); mu=mu_init;
g_rms=sqrt(mean(g.^2)); if g_rms>0, g_n=g/g_rms; else, g_n=g; end
g_sq=sum(g.^2);
dOmega=lc_obs.dOmega; F_obs=sum(dOmega.*sum(abs(J_obs).^2,2)); if F_obs<1e-60, F_obs=1.0; end
accepted=false; F_new=F_old; c=0.01; dec=0.5; Nt=8;
fprintf('  [LS] F_old=%.6e mu=%.4f\n', F_old, mu);
for t=1:Nt
    et=max(1.0,min(50.0,eps_old-mu*g_n));
    ef=voxel.epsilon_r; ef(inner)=et;
    update_epsilon(model,voxel,p); voxel.epsilon_r=ef;
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll();
    sf=extract_scattered(model,grid_meas); lc=lightcone_project(grid_meas,sf,p);
    F_new=sum(dOmega.*sum(abs(J_obs-lc.J_obs_perp).^2,2))/F_obs;
    arm=F_old-c*mu*g_sq;
    fprintf('  [LS t%d] mu=%.6f F=%.6e armijo=%.6e',t,mu,F_new,arm);
    if F_new<=arm
        fprintf(' ACCEPT\n'); voxel.epsilon_r(inner)=et; accepted=true; break;
    else, fprintf(' reject\n'); mu=mu*dec; end
end
if ~accepted, F_new=F_old; mu_next=mu_init*0.5; else, mu_next=min(mu*1.5,5.0); end
end

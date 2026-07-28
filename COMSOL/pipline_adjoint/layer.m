function out = model
%
% layer.m
%
% Model exported on Jul 28 2026, 00:45 by COMSOL 6.2.0.290.

import com.comsol.model.*
import com.comsol.model.util.*

model = ModelUtil.create('Model');

model.modelPath('D:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');

model.component.create('comp1', true);

model.component('comp1').geom.create('geom1', 3);

model.component('comp1').mesh.create('mesh1');

model.component('comp1').physics.create('emw', 'ElectromagneticWaves', 'geom1');

model.study.create('std1');
model.study('std1').create('freq', 'Frequency');
model.study('std1').feature('freq').set('solnum', 'auto');
model.study('std1').feature('freq').set('notsolnum', 'auto');
model.study('std1').feature('freq').set('outputmap', {});
model.study('std1').feature('freq').set('ngenAUX', '1');
model.study('std1').feature('freq').set('goalngenAUX', '1');
model.study('std1').feature('freq').set('ngenAUX', '1');
model.study('std1').feature('freq').set('goalngenAUX', '1');
model.study('std1').feature('freq').setSolveFor('/physics/emw', true);

model.component('comp1').geom('geom1').create('sph1', 'Sphere');
model.component('comp1').geom('geom1').feature('sph1').set('r', 0.16);
model.component('comp1').geom('geom1').feature('sph1').setIndex('layer', 0.04, 0);
model.component('comp1').geom('geom1').feature('sph1').setIndex('layer', 0.06, 1);
model.component('comp1').geom('geom1').runPre('fin');

model.component('comp1').view('view1').set('transparency', true);

model.component('comp1').coordSystem.create('pml1', 'PML');

model.component('comp1').geom('geom1').run;

model.component('comp1').coordSystem('pml1').selection.set([1 2 3 4 10 11 14 17]);

model.component('comp1').physics('emw').prop('BackgroundField').set('SolveFor', 'scatteredField');
model.component('comp1').physics('emw').prop('BackgroundField').set('Eb', [1 0 0]);

model.component('comp1').material.create('mat1', 'Common');
model.component('comp1').material('mat1').propertyGroup('def').set('relpermittivity', {'1'});
model.component('comp1').material('mat1').propertyGroup('def').set('relpermeability', {'1'});
model.component('comp1').material('mat1').propertyGroup('def').set('electricconductivity', {'0'});

model.component('comp1').physics('emw').prop('BackgroundField').set('Eb', [0 0 1]);

model.study.create('std2');
model.study('std2').create('freq', 'Frequency');
model.study('std2').feature('freq').set('solnum', 'auto');
model.study('std2').feature('freq').set('notsolnum', 'auto');
model.study('std2').feature('freq').set('outputmap', {});
model.study('std2').feature('freq').set('ngenAUX', '1');
model.study('std2').feature('freq').set('goalngenAUX', '1');
model.study('std2').feature('freq').set('ngenAUX', '1');
model.study('std2').feature('freq').set('goalngenAUX', '1');
model.study('std2').feature('freq').setSolveFor('/physics/emw', true);

model.sol.create('sol1');
model.sol('sol1').study('std1');
model.sol('sol1').attach('std1');

model.component('comp1').coordSystem('pml1').set('ScalingType', 'Spherical');

model.sol.create('sol2');
model.sol('sol2').study('std2');
model.sol('sol2').create('st1', 'StudyStep');
model.sol('sol2').feature('st1').set('study', 'std2');
model.sol('sol2').feature('st1').set('studystep', 'freq');
model.sol('sol2').create('v1', 'Variables');
model.sol('sol2').feature('v1').set('control', 'freq');
model.sol('sol2').create('s1', 'Stationary');
model.sol('sol2').feature('s1').set('stol', 0.01);
model.sol('sol2').feature('s1').create('p1', 'Parametric');
model.sol('sol2').feature('s1').feature.remove('pDef');
model.sol('sol2').feature('s1').feature('p1').set('pname', {'freq'});
model.sol('sol2').feature('s1').feature('p1').set('plistarr', {'1[GHz]'});
model.sol('sol2').feature('s1').feature('p1').set('punit', {'GHz'});
model.sol('sol2').feature('s1').feature('p1').set('pcontinuationmode', 'no');
model.sol('sol2').feature('s1').feature('p1').set('preusesol', 'no');
model.sol('sol2').feature('s1').feature('p1').set('pdistrib', 'off');
model.sol('sol2').feature('s1').feature('p1').set('plot', 'off');
model.sol('sol2').feature('s1').feature('p1').set('plotgroup', 'Default');
model.sol('sol2').feature('s1').feature('p1').set('probesel', 'all');
model.sol('sol2').feature('s1').feature('p1').set('probes', {});
model.sol('sol2').feature('s1').feature('p1').set('control', 'freq');
model.sol('sol2').feature('s1').set('linpmethod', 'sol');
model.sol('sol2').feature('s1').set('linpsol', 'zero');
model.sol('sol2').feature('s1').set('control', 'freq');
model.sol('sol2').feature('s1').feature('aDef').set('complexfun', true);
model.sol('sol2').feature('s1').feature('aDef').set('cachepattern', false);
model.sol('sol2').feature('s1').create('fc1', 'FullyCoupled');
model.sol('sol2').feature('s1').create('i1', 'Iterative');
model.sol('sol2').feature('s1').feature('i1').set('linsolver', 'gmres');
model.sol('sol2').feature('s1').feature('i1').set('prefuntype', 'right');
model.sol('sol2').feature('s1').feature('i1').set('itrestart', '300');
model.sol('sol2').feature('s1').feature('i1').label([native2unicode(hex2dec({'5e' 'fa'}), 'unicode')  native2unicode(hex2dec({'8b' 'ae'}), 'unicode')  native2unicode(hex2dec({'76' '84'}), 'unicode')  native2unicode(hex2dec({'8f' 'ed'}), 'unicode')  native2unicode(hex2dec({'4e' 'e3'}), 'unicode')  native2unicode(hex2dec({'6c' '42'}), 'unicode')  native2unicode(hex2dec({'89' 'e3'}), 'unicode')  native2unicode(hex2dec({'56' '68'}), 'unicode') ' (emw)']);
model.sol('sol2').feature('s1').feature('i1').create('mg1', 'Multigrid');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').set('iter', '1');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('pr').create('sv1', 'SORVector');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('prefun', 'sorvec');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('iter', 2);
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('relax', 1);
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('po').create('sv1', 'SORVector');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('prefun', 'soruvec');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('iter', 2);
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('relax', 1);
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('cs').create('d1', 'Direct');
model.sol('sol2').feature('s1').feature('i1').feature('mg1').feature('cs').feature('d1').set('linsolver', 'pardiso');
model.sol('sol2').feature('s1').feature('fc1').set('linsolver', 'i1');
model.sol('sol2').feature('s1').feature.remove('fcDef');
model.sol('sol2').attach('std2');
model.sol('sol2').runAll;

model.result.create('pg1', 'PlotGroup3D');
model.result('pg1').label([native2unicode(hex2dec({'75' '35'}), 'unicode')  native2unicode(hex2dec({'57' '3a'}), 'unicode') ' (emw)']);
model.result('pg1').set('data', 'dset2');
model.result('pg1').setIndex('looplevel', 1, 0);
model.result('pg1').set('frametype', 'spatial');
model.result('pg1').set('showlegendsmaxmin', true);
model.result('pg1').set('data', 'dset2');
model.result('pg1').setIndex('looplevel', 1, 0);
model.result('pg1').set('defaultPlotID', 'ElectromagneticWaves/phys1/pdef1/pcond1/pg1');
model.result('pg1').feature.create('mslc1', 'Multislice');
model.result('pg1').feature('mslc1').label([native2unicode(hex2dec({'59' '1a'}), 'unicode')  native2unicode(hex2dec({'52' '07'}), 'unicode')  native2unicode(hex2dec({'97' '62'}), 'unicode') ]);
model.result('pg1').feature('mslc1').set('smooth', 'internal');
model.result('pg1').feature('mslc1').set('data', 'parent');
model.result('pg1').feature('mslc1').feature.create('filt1', 'Filter');
model.result('pg1').feature('mslc1').feature('filt1').set('expr', '!isScalingSystemDomain');
model.result('pg1').run;
model.result('pg1').run;
model.result('pg1').run;
model.result('pg1').feature('mslc1').set('expr', 'emw.relEx');
model.result('pg1').run;

model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').run;

model.component('comp1').geom('geom1').feature('sph1').setIndex('layer', 0.03, 2);
model.component('comp1').geom('geom1').runPre('fin');
model.component('comp1').geom('geom1').run;

model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').autoMeshSize(9);
model.component('comp1').mesh('mesh1').run;

model.study.remove('std2');

model.sol('sol1').study('std1');
model.sol('sol1').create('st1', 'StudyStep');
model.sol('sol1').feature('st1').set('study', 'std1');
model.sol('sol1').feature('st1').set('studystep', 'freq');
model.sol('sol1').create('v1', 'Variables');
model.sol('sol1').feature('v1').set('control', 'freq');
model.sol('sol1').create('s1', 'Stationary');
model.sol('sol1').feature('s1').set('stol', 0.01);
model.sol('sol1').feature('s1').create('p1', 'Parametric');
model.sol('sol1').feature('s1').feature.remove('pDef');
model.sol('sol1').feature('s1').feature('p1').set('pname', {'freq'});
model.sol('sol1').feature('s1').feature('p1').set('plistarr', {'1[GHz]'});
model.sol('sol1').feature('s1').feature('p1').set('punit', {'GHz'});
model.sol('sol1').feature('s1').feature('p1').set('pcontinuationmode', 'no');
model.sol('sol1').feature('s1').feature('p1').set('preusesol', 'no');
model.sol('sol1').feature('s1').feature('p1').set('pdistrib', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plot', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plotgroup', 'Default');
model.sol('sol1').feature('s1').feature('p1').set('probesel', 'all');
model.sol('sol1').feature('s1').feature('p1').set('probes', {});
model.sol('sol1').feature('s1').feature('p1').set('control', 'freq');
model.sol('sol1').feature('s1').set('linpmethod', 'sol');
model.sol('sol1').feature('s1').set('linpsol', 'zero');
model.sol('sol1').feature('s1').set('control', 'freq');
model.sol('sol1').feature('s1').feature('aDef').set('complexfun', true);
model.sol('sol1').feature('s1').feature('aDef').set('cachepattern', false);
model.sol('sol1').feature('s1').create('fc1', 'FullyCoupled');
model.sol('sol1').feature('s1').create('i1', 'Iterative');
model.sol('sol1').feature('s1').feature('i1').set('linsolver', 'gmres');
model.sol('sol1').feature('s1').feature('i1').set('prefuntype', 'right');
model.sol('sol1').feature('s1').feature('i1').set('itrestart', '300');
model.sol('sol1').feature('s1').feature('i1').label([native2unicode(hex2dec({'5e' 'fa'}), 'unicode')  native2unicode(hex2dec({'8b' 'ae'}), 'unicode')  native2unicode(hex2dec({'76' '84'}), 'unicode')  native2unicode(hex2dec({'8f' 'ed'}), 'unicode')  native2unicode(hex2dec({'4e' 'e3'}), 'unicode')  native2unicode(hex2dec({'6c' '42'}), 'unicode')  native2unicode(hex2dec({'89' 'e3'}), 'unicode')  native2unicode(hex2dec({'56' '68'}), 'unicode') ' (emw)']);
model.sol('sol1').feature('s1').feature('i1').create('mg1', 'Multigrid');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').set('iter', '1');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('prefun', 'sorvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('prefun', 'soruvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').create('d1', 'Direct');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').feature('d1').set('linsolver', 'pardiso');
model.sol('sol1').feature('s1').feature('fc1').set('linsolver', 'i1');
model.sol('sol1').feature('s1').feature.remove('fcDef');
model.sol('sol1').attach('std1');
model.sol('sol1').runAll;

model.result.create('pg1', 'PlotGroup3D');
model.result('pg1').label([native2unicode(hex2dec({'75' '35'}), 'unicode')  native2unicode(hex2dec({'57' '3a'}), 'unicode') ' (emw)']);
model.result('pg1').set('frametype', 'spatial');
model.result('pg1').set('showlegendsmaxmin', true);
model.result('pg1').set('data', 'dset1');
model.result('pg1').setIndex('looplevel', 1, 0);
model.result('pg1').set('defaultPlotID', 'ElectromagneticWaves/phys1/pdef1/pcond1/pg1');
model.result('pg1').feature.create('mslc1', 'Multislice');
model.result('pg1').feature('mslc1').label([native2unicode(hex2dec({'59' '1a'}), 'unicode')  native2unicode(hex2dec({'52' '07'}), 'unicode')  native2unicode(hex2dec({'97' '62'}), 'unicode') ]);
model.result('pg1').feature('mslc1').set('smooth', 'internal');
model.result('pg1').feature('mslc1').set('data', 'parent');
model.result('pg1').feature('mslc1').feature.create('filt1', 'Filter');
model.result('pg1').feature('mslc1').feature('filt1').set('expr', '!isScalingSystemDomain');
model.result('pg1').run;

model.component('comp1').material.create('mat2', 'Common');

model.component('comp1').view('view1').hideEntities.create('hide1');
model.component('comp1').view('view1').hideEntities('hide1').geom(3);
model.component('comp1').view('view1').hideEntities('hide1').add([15]);
model.component('comp1').view('view1').hideEntities('hide1').add([25]);
model.component('comp1').view('view1').hideEntities('hide1').add([4]);
model.component('comp1').view('view1').hideEntities('hide1').add([2]);
model.component('comp1').view('view1').hideEntities('hide1').add([14]);
model.component('comp1').view('view1').hideEntities('hide1').add([20]);
model.component('comp1').view('view1').hideEntities('hide1').add([3]);
model.component('comp1').view('view1').hideEntities('hide1').add([1]);

model.component('comp1').material.create('mat3', 'Common');
model.component('comp1').material('mat2').selection.set([5 6 7 8 16 17 21 24]);
model.component('comp1').material('mat2').propertyGroup('def').set('relpermittivity', {'10'});
model.component('comp1').material('mat2').propertyGroup('def').set('relpermeability', {'1'});
model.component('comp1').material('mat2').propertyGroup('def').set('electricconductivity', {'0'});
model.component('comp1').material('mat2').selection.set([]);

model.component('comp1').view('view1').hideEntities('hide1').add([7]);
model.component('comp1').view('view1').hideEntities('hide1').add([21]);
model.component('comp1').view('view1').hideEntities('hide1').add([24]);
model.component('comp1').view('view1').hideEntities('hide1').add([8]);
model.component('comp1').view('view1').hideEntities('hide1').add([5]);
model.component('comp1').view('view1').hideEntities('hide1').add([16]);
model.component('comp1').view('view1').hideEntities('hide1').add([6]);
model.component('comp1').view('view1').hideEntities('hide1').add([17]);

model.component('comp1').material('mat2').selection.set([9 10 11 12 18 19 22 23]);

model.component('comp1').view('view1').hideEntities('hide1').add([12]);

model.component('comp1').material('mat3').selection.set([13]);
model.component('comp1').material('mat3').propertyGroup('def').set('relpermittivity', {'5'});
model.component('comp1').material('mat3').propertyGroup('def').set('relpermeability', {'1'});
model.component('comp1').material('mat3').propertyGroup('def').set('electricconductivity', {'0'});

model.component('comp1').mesh('mesh1').run;

model.component('comp1').view('view1').hideObjects.clear;
model.component('comp1').view('view1').hideEntities.clear;

model.sol('sol1').study('std1');
model.sol('sol1').feature.remove('s1');
model.sol('sol1').feature.remove('v1');
model.sol('sol1').feature.remove('st1');
model.sol('sol1').create('st1', 'StudyStep');
model.sol('sol1').feature('st1').set('study', 'std1');
model.sol('sol1').feature('st1').set('studystep', 'freq');
model.sol('sol1').create('v1', 'Variables');
model.sol('sol1').feature('v1').set('control', 'freq');
model.sol('sol1').create('s1', 'Stationary');
model.sol('sol1').feature('s1').set('stol', 0.01);
model.sol('sol1').feature('s1').create('p1', 'Parametric');
model.sol('sol1').feature('s1').feature.remove('pDef');
model.sol('sol1').feature('s1').feature('p1').set('pname', {'freq'});
model.sol('sol1').feature('s1').feature('p1').set('plistarr', {'1[GHz]'});
model.sol('sol1').feature('s1').feature('p1').set('punit', {'GHz'});
model.sol('sol1').feature('s1').feature('p1').set('pcontinuationmode', 'no');
model.sol('sol1').feature('s1').feature('p1').set('preusesol', 'no');
model.sol('sol1').feature('s1').feature('p1').set('pdistrib', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plot', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plotgroup', 'pg1');
model.sol('sol1').feature('s1').feature('p1').set('probesel', 'all');
model.sol('sol1').feature('s1').feature('p1').set('probes', {});
model.sol('sol1').feature('s1').feature('p1').set('control', 'freq');
model.sol('sol1').feature('s1').set('linpmethod', 'sol');
model.sol('sol1').feature('s1').set('linpsol', 'zero');
model.sol('sol1').feature('s1').set('control', 'freq');
model.sol('sol1').feature('s1').feature('aDef').set('complexfun', true);
model.sol('sol1').feature('s1').feature('aDef').set('cachepattern', false);
model.sol('sol1').feature('s1').create('fc1', 'FullyCoupled');
model.sol('sol1').feature('s1').create('i1', 'Iterative');
model.sol('sol1').feature('s1').feature('i1').set('linsolver', 'gmres');
model.sol('sol1').feature('s1').feature('i1').set('prefuntype', 'right');
model.sol('sol1').feature('s1').feature('i1').set('itrestart', '300');
model.sol('sol1').feature('s1').feature('i1').label([native2unicode(hex2dec({'5e' 'fa'}), 'unicode')  native2unicode(hex2dec({'8b' 'ae'}), 'unicode')  native2unicode(hex2dec({'76' '84'}), 'unicode')  native2unicode(hex2dec({'8f' 'ed'}), 'unicode')  native2unicode(hex2dec({'4e' 'e3'}), 'unicode')  native2unicode(hex2dec({'6c' '42'}), 'unicode')  native2unicode(hex2dec({'89' 'e3'}), 'unicode')  native2unicode(hex2dec({'56' '68'}), 'unicode') ' (emw)']);
model.sol('sol1').feature('s1').feature('i1').create('mg1', 'Multigrid');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').set('iter', '1');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('prefun', 'sorvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('prefun', 'soruvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').create('d1', 'Direct');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').feature('d1').set('linsolver', 'pardiso');
model.sol('sol1').feature('s1').feature('fc1').set('linsolver', 'i1');
model.sol('sol1').feature('s1').feature.remove('fcDef');
model.sol('sol1').attach('std1');
model.sol('sol1').runAll;

model.result('pg1').run;

model.component('comp1').func.create('int1', 'Interpolation');
model.component('comp1').func('int1').set('funcname', 'int2');
model.component('comp1').func('int1').setIndex('table', 'x', 0, 0);
model.component('comp1').func('int1').setIndex('table', 'y', 1, 0);
model.component('comp1').func('int1').setIndex('table', 'z', 2, 0);
model.component('comp1').func('int1').set('source', 'function');
model.component('comp1').func('int1').set('defvars', false);
model.component('comp1').func('int1').set('source', 'file');
model.component('comp1').func('int1').remove('funcs', 0);
model.component('comp1').func('int1').set('source', 'table');
model.component('comp1').func('int1').setIndex('table', '0    0    0    1', 0, 0);
model.component('comp1').func('int1').setIndex('table', '', 0, 1);
model.component('comp1').func('int1').setIndex('table', '0.02  0    0    1', 1, 0);
model.component('comp1').func('int1').setIndex('table', '', 1, 1);
model.component('comp1').func('int1').setIndex('table', '0    0.02 0    1', 2, 0);
model.component('comp1').func('int1').setIndex('table', '', 2, 1);
model.component('comp1').func('int1').setIndex('table', '0    0    0.02 1', 3, 0);
model.component('comp1').func('int1').setIndex('table', '', 3, 1);
model.component('comp1').func('int1').setIndex('table', '-0.02 0    0    1', 4, 0);
model.component('comp1').func('int1').setIndex('table', '', 4, 1);
model.component('comp1').func('int1').setIndex('table', '0    -0.02 0    1', 5, 0);
model.component('comp1').func('int1').setIndex('table', '', 5, 1);
model.component('comp1').func('int1').setIndex('table', '0    0    -0.02 1', 6, 0);
model.component('comp1').func('int1').setIndex('table', '', 6, 1);
model.component('comp1').func('int1').set('table', {});
model.component('comp1').func('int1').set('source', 'resultTable');
model.component('comp1').func('int1').set('nargs', 3);
model.component('comp1').func('int1').set('source', 'table');
model.component('comp1').func('int1').set('argtrans', 'none');
model.component('comp1').func('int1').set('source', 'file');
model.component('comp1').func('int1').set('filename', 'D:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint\eps_init.txt');
model.component('comp1').func('int1').label([native2unicode(hex2dec({'63' 'd2'}), 'unicode')  native2unicode(hex2dec({'50' '3c'}), 'unicode') ' 2']);
model.component('comp1').func('int1').set('dseparator', 'comma');
model.component('comp1').func('int1').setIndex('funcs', 'int2', 0, 0);
model.component('comp1').func('int1').set('defvars', true);
model.component('comp1').func('int1').setIndex('argunit', 'x', 0);
model.component('comp1').func('int1').setIndex('argunit', 'm', 0);
model.component('comp1').func('int1').setIndex('argunit', 'm', 1);
model.component('comp1').func('int1').setIndex('argunit', 'm', 2);
model.component('comp1').func('int1').setIndex('funcs', 0, 0, 1);
model.component('comp1').func('int1').setIndex('funcs', 1, 0, 1);
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').refresh;
model.component('comp1').func('int1').label([native2unicode(hex2dec({'63' 'd2'}), 'unicode')  native2unicode(hex2dec({'50' '3c'}), 'unicode') ' 1']);
model.component('comp1').func('int1').setIndex('funcs', 'int1', 0, 0);
model.component('comp1').func.create('int2', 'Interpolation');
model.component('comp1').func('int2').set('source', 'file');
model.component('comp1').func('int2').set('filename', 'D:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint\eps_init_im.txt');
model.component('comp1').func('int2').setIndex('argunit', 'm', 0);
model.component('comp1').func('int2').setIndex('argunit', 'm', 1);
model.component('comp1').func('int2').setIndex('argunit', 'm', 2);
model.component('comp1').func('int2').set('defvars', true);
model.component('comp1').func('int1').set('dseparator', 'point');

model.component('comp1').physics('emw').prop('PortSweepSettings').set('useSweep', false);
model.component('comp1').physics('emw').feature('wee1').set('epsilonr_mat', 'userdef');
model.component('comp1').physics('emw').feature('wee1').set('epsilonr', {'int1(x,y,z) + i*int2(x,y,z)' '0' '0' '0' 'int1(x,y,z) + i*int2(x,y,z)' '0' '0' '0' 'int1(x,y,z) + i*int2(x,y,z)'});

model.component('comp1').material('mat3').active(false);
model.component('comp1').material('mat2').active(false);

model.sol('sol1').study('std1');
model.sol('sol1').feature.remove('st1');
model.sol('sol1').feature.remove('v1');
model.sol('sol1').feature.remove('s1');
model.sol('sol1').attach('std1');

model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').feature('ftet1').active(false);
model.component('comp1').mesh('mesh1').feature.remove('ftet1');
model.component('comp1').mesh('mesh1').automatic(true);
model.component('comp1').mesh('mesh1').feature('size').set('custom', false);
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').automatic(true);
model.component('comp1').mesh('mesh1').feature('size').set('custom', false);
model.component('comp1').mesh('mesh1').feature('size').set('table', 'coarseadaptation');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').feature('size').set('table', 'timeexplicitwave');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run;

model.sol('sol1').study('std1');
model.sol('sol1').create('st1', 'StudyStep');
model.sol('sol1').feature('st1').set('study', 'std1');
model.sol('sol1').feature('st1').set('studystep', 'freq');
model.sol('sol1').create('v1', 'Variables');
model.sol('sol1').feature('v1').set('control', 'freq');
model.sol('sol1').create('s1', 'Stationary');
model.sol('sol1').feature('s1').set('stol', 0.01);
model.sol('sol1').feature('s1').create('p1', 'Parametric');
model.sol('sol1').feature('s1').feature.remove('pDef');
model.sol('sol1').feature('s1').feature('p1').set('pname', {'freq'});
model.sol('sol1').feature('s1').feature('p1').set('plistarr', {'1[GHz]'});
model.sol('sol1').feature('s1').feature('p1').set('punit', {'GHz'});
model.sol('sol1').feature('s1').feature('p1').set('pcontinuationmode', 'no');
model.sol('sol1').feature('s1').feature('p1').set('preusesol', 'no');
model.sol('sol1').feature('s1').feature('p1').set('pdistrib', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plot', 'off');
model.sol('sol1').feature('s1').feature('p1').set('plotgroup', 'pg1');
model.sol('sol1').feature('s1').feature('p1').set('probesel', 'all');
model.sol('sol1').feature('s1').feature('p1').set('probes', {});
model.sol('sol1').feature('s1').feature('p1').set('control', 'freq');
model.sol('sol1').feature('s1').set('linpmethod', 'sol');
model.sol('sol1').feature('s1').set('linpsol', 'zero');
model.sol('sol1').feature('s1').set('control', 'freq');
model.sol('sol1').feature('s1').feature('aDef').set('complexfun', true);
model.sol('sol1').feature('s1').feature('aDef').set('cachepattern', false);
model.sol('sol1').feature('s1').create('fc1', 'FullyCoupled');
model.sol('sol1').feature('s1').create('i1', 'Iterative');
model.sol('sol1').feature('s1').feature('i1').set('linsolver', 'gmres');
model.sol('sol1').feature('s1').feature('i1').set('prefuntype', 'right');
model.sol('sol1').feature('s1').feature('i1').set('itrestart', '300');
model.sol('sol1').feature('s1').feature('i1').label([native2unicode(hex2dec({'5e' 'fa'}), 'unicode')  native2unicode(hex2dec({'8b' 'ae'}), 'unicode')  native2unicode(hex2dec({'76' '84'}), 'unicode')  native2unicode(hex2dec({'8f' 'ed'}), 'unicode')  native2unicode(hex2dec({'4e' 'e3'}), 'unicode')  native2unicode(hex2dec({'6c' '42'}), 'unicode')  native2unicode(hex2dec({'89' 'e3'}), 'unicode')  native2unicode(hex2dec({'56' '68'}), 'unicode') ' (emw)']);
model.sol('sol1').feature('s1').feature('i1').create('mg1', 'Multigrid');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').set('iter', '1');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('prefun', 'sorvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('pr').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').create('sv1', 'SORVector');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('prefun', 'soruvec');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('iter', 2);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('relax', 1);
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('po').feature('sv1').set('sorvecdof', {'comp1_E'});
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').create('d1', 'Direct');
model.sol('sol1').feature('s1').feature('i1').feature('mg1').feature('cs').feature('d1').set('linsolver', 'pardiso');
model.sol('sol1').feature('s1').feature('fc1').set('linsolver', 'i1');
model.sol('sol1').feature('s1').feature.remove('fcDef');
model.sol('sol1').attach('std1');
model.sol('sol1').runAll;

model.result('pg1').run;

model.component('comp1').mesh('mesh1').feature('size').set('table', 'default');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').feature('size').set('custom', false);
model.component('comp1').mesh('mesh1').feature('size').set('hauto', 5);
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run;
model.component('comp1').mesh('mesh1').feature('size').set('table', 'timeexplicitwave');
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('ftet1');
model.component('comp1').mesh('mesh1').feature('size').set('hauto', 9);
model.component('comp1').mesh('mesh1').run('size');
model.component('comp1').mesh('mesh1').run('ftet1');

out = model;

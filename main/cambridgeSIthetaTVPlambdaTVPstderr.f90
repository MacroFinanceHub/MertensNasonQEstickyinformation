PROGRAM main

  ! time-varying AR1

  USE embox, only : hrulefill, loadmatrix, loadarray1, savemat, savematlogical, savevec, storeEstimates, loft, timestampstr, es30d16, int2str
  USE blaspack, only : vech, ivech, eye
  USE gibbsbox, only : drawNDXpdf, drawNDXsysresample

  USE vslbox
  USE timerbox
  USE omp_lib

  IMPLICIT NONE

  ! ----------------------------------------------------------------------------------

  CHARACTER (LEN=200) :: modellabel ='SIthetaTVPlambdaTVPSTDERR'
  INTEGER  :: Ngrid = 500

  logical, parameter :: doTimestamp = .false., doSmoother = .false., doGains = .false.
  logical :: doInflationNoise = .false.


  logical :: doSecondResamplingStep = .false.
  
  double precision :: priornoisevol = sqrt(0.1d0)

  INTEGER, PARAMETER :: dof0 = 3

  INTEGER, PARAMETER :: p = 1, Nsurveys = 5, Ny = Nsurveys + 1, Nx = 2 * (1 + p), NsigmaX = Nx * (Nx + 1) / 2, Nw = 2, Nsv = 2
  INTEGER, PARAMETER :: ndxtrendRE = 1 , ndxgapRE = 2 , ndxtrendSI = 1 + p + 1 , ndxgapSI = ndxtrendSI + 1
  ! DOUBLE PRECISION, DIMENSION(Nsurveys), PARAMETER :: horizons = (/1,2,3,4,5/)

  INTEGER :: Nparticles ! Nsmoother, NsmootherX, Nmixturedraws
  INTEGER :: T,i,k,status 

  DOUBLE PRECISION, DIMENSION(Nx,Nx) :: sqrtVx0
  DOUBLE PRECISION, DIMENSION(Nx)    :: Ex0
  DOUBLE PRECISION, DIMENSION(Nsv)   :: SVar0, Eh0, Vh0

  DOUBLE PRECISION :: lambda0, lambda0V
  DOUBLE PRECISION :: a0, a0V 


  ! priors for scale parameters
  DOUBLE PRECISION :: sigaT, siglambdaT, hvarT(Nsv), sigmaT(Ny)
  INTEGER :: sigaDof, siglambdaDof, hvarDof(Nsv), sigmaDof(Ny)


  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: y
  LOGICAL, ALLOCATABLE, DIMENSION(:,:) :: yNaN
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:)   :: logMDD
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:)   :: ESS



  TYPE(progresstimer) :: gridtimer
  INTEGER :: gridCount

  CHARACTER (LEN=200) :: filename, datafile, nandatafile, fileXT, datalabel

  ! VSL Random Stuff
  type (vsl_stream_state) :: VSLstream
  integer :: seed
  ! integer :: brng
  integer :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0

  ! OPEN MP
  INTEGER :: NTHREADS, TID


  ! ----------------------------------------------------------------------------------
  ! MODEL PARAMETERS
  ! ----------------------------------------------------------------------------------
  ! runtime parameters :start:
  ! first: set default values

  ! thorough
  Nparticles    = 10 ** 5
  ! quick
  Nparticles    = 10 ** 3
  Ngrid         = 10

  datalabel = ''
  call getarguments(Nparticles,Ngrid,doInflationNoise,datalabel, doSecondResamplingStep)


  ! ----------------------------------------------------------------------------------
  ! INIT
  ! ----------------------------------------------------------------------------------

  ! INIT OMP
  NTHREADS = 1
  !$OMP PARALLEL SHARED(NTHREADS)
  !$ NTHREADS = OMP_GET_NUM_THREADS()
  !$OMP END PARALLEL
  print *, "Number of Threads:", NTHREADS

  ! runtime parameters :end: 

  if (doSecondResamplingStep) then
     print *, 'APF uses second resampling step'
  end if
  if (doInflationNoise) then
     print *, 'Model variant with Noise in Inflation'
  else
     print *, 'Model variant WITHOUT Noise in Inflation'
  end if
  ! CONSTRUCT FILE EXTENTSIONS
  fileXT = '.particles.' // trim(datalabel) // '.' // trim(modellabel)
  if (.not. doInflationNoise)  fileXT = trim(filext) // '.nonoise'
  if (doSecondResamplingStep)  fileXT = trim(filext) // '.2ndAPFresample'
  fileXT = trim(filext) // '.Ngrid' // trim(int2str(Ngrid)) // '.Nparticles' // trim(int2str(Nparticles)) // '.dat'
  if (doTimeStamp) filext = '.' // timestampstr() //  filext

  datafile    = trim(datalabel) // '.yData.txt'
  nandatafile = trim(datalabel) // '.yNaN.txt'

  ! read data
  T = loft(datafile) 
  IF (T < 10) THEN
     print *, 'Less than 10 observations in input file!', datafile
     STOP 1
  END IF

  ALLOCATE (y(Ny,T), yNaN(Ny,T), STAT=status)
  IF (status /= 0) THEN
     WRITE (*,*) 'Allocation problem (Y)'
  END IF

  ! print *, 'trying to read', T, 'obs from', datafile
  CALL readdata(y,datafile,Ny,T)
  CALL readnandata(yNaN,nandatafile,Ny,T)

  ! validate yNaN and y
  DO k=1,T
     DO i = 1, Ny
        if (yNaN(i,k) .AND. y(i,k) /= 0.0d0 ) then
           write (*,*) 'YNAN PATTERN DOES NOT MATCH ZEROS IN Y'
        end if
     END DO
  END DO



  ! trivial since Nsv = 1 here
  Svar0    = (/ 0.6 / 3.0d0, 0.6 * 2.0d0 / 3.0d0 /)
  Vh0      = 10.0d0
  Eh0      = log(Svar0) - Vh0 * 0.5d0

  hvarDof = dof0
  hvarT   = (0.2d0 ** 2) * (dble(hvarDof) - 2.0d0)

  ! lambda
  lambda0      = .5d0
  lambda0V     = 1.0d0
  siglambdaDof = dof0
  siglambdaT   = (0.1d0 ** 2) * (dble(siglambdaDof) - 2.0d0)

  ! a
  a0        = 0.0d0
  a0V       = 1.0d0
  sigaDof   = dof0
  sigaT     = (0.1d0 ** 2) * (dble(sigaDof) - 2.0d0)

  ! Linear prior
  Ex0       = 0.0d0
  Ex0(1)    = 2.0d0
  Ex0(2+p)  = 2.0d0

  ! sqrtVx0, expressed as lower  triangular-choleski factor (sqrtVx0 * sqrtVx0')
  call eye(sqrtVx0, 10.0d0) ! non-zero prior gap-variance matters only for initial conditions for sampling lagged gap as used for estimating AR(1) coefficient 
  sqrtVx0(1,1) = 100.0d0 ! sqrt(2.0d0)
  sqrtVx0(2+p,2+p) = 100.0d0 ! sqrt(2.0d0) 

  sigmaDof    = 20 ! dof0
  sigmaT      = (priornoisevol ** 2) * (dble(sigmaDof) - 2.0d0)


  ! REPORT PARAMETERS TO SCREEN
  CALL HRULEFILL
  print *, 'data=       ' // datalabel
  print *, 'model=      ' // modellabel
  print *, 'Ngrid=      ', Ngrid
  print *, 'Ny=         ', Ny
  print *, 'T=          ', T
  print *, 'Nparticles= ', Nparticles
  ! print *, 'Nsmoother= ', Nsmoother
  print *, 'p=          ', p
  CALL HRULEFILL

  ALLOCATE (logMDD(T,Ngrid))
  ALLOCATE (ESS(T,Ngrid))

  CALL initprogressbar(gridtimer, 15.0d0)
  gridCount = 0

  !$OMP PARALLEL DO SHARED(doSecondResamplingStep,doInflationNoise,logMDD,ESS,gridCount,gridtimer,Nparticles,T,Ngrid,y,yNaN,Ex0,sqrtVx0,A0,A0V,SigAT,SigAdof,LAMBDA0,LAMBDA0V,siglambdaT,siglambdaDof,Eh0,Vh0,hvarT,hvarDof,sigmaT,sigmaDof) PRIVATE(TID,VSLstream,seed,errcode)  DEFAULT(NONE) SCHEDULE(DYNAMIC)

  DO i=1,Ngrid

     !OMP ATOMIC
     gridCount = gridCount + 1


     ! VSL
     TID = 0
     !$ TID = OMP_GET_THREAD_NUM()
     seed = 1 + i
     errcode = vslnewstream(VSLstream, vsl_brng_mt2203, seed)  
     if (errcode /= 0) then
        print *,'VSLstream failed to init'
        stop 1
     end if
     ! WRITE(*,'(a25, i20, i20)') 'LAUNCHING VSLSTREAM ', VSLstream%descriptor1, VSLstream%descriptor2
     ! print *, 'vsl_brng', vsl_brng_mt2203



     CALL particleLLF(doSecondResamplingStep, doInflationNoise,T, logMDD(:,i), ESS(:,i), Ny, y, yNaN, Nparticles, Nx, NsigmaX, Nw, Ex0, sqrtVx0, p, a0, a0V, sigaT, sigaDof, lambda0, lambda0V, siglambdaT, siglambdaDof, Nsv, Eh0, Vh0, hvarT, hvarDof, sigmaT, sigmaDof, VSLstream)


     ! LOG-MDD
     WRITE (*,*) '... the logMDD is ', sum(logMDD(:,i))

     ! VSLstreams
     errcode = vsldeletestream(VSLstream)     

     ! call hrulefill
     CALL progressbarcomment(dble(gridCount) / dble(Ngrid), gridtimer, 'LLF grid')
     ! call hrulefill

  END DO ! llf grid
  !$OMP END PARALLEL DO

  ! WRITE SETTINGS
  CALL HRULEFILL
  filename = 'settings' // trim(adjustl(filext))
  OPEN (UNIT=4, FILE=filename, STATUS='REPLACE', ACTION='WRITE')
  WRITE(4,'(a20,a40)') 'TIME: ', timestampstr()
  WRITE(4,'(a20,a40)') 'Data: ', datalabel
  WRITE(4,'(a20,a40)') 'Model: ', modellabel
  WRITE(4,'(a60)') repeat('-',60)
  WRITE(4,'(a20,I40)') 'Nparticles: ', Nparticles
  WRITE(4,'(a20,I40)') 'Ngrid: ', Ngrid
  WRITE(4,'(a20,I40)') 'p: ', p
  if (doInflationNoise) THEN
     WRITE(4,'(a60)') 'With noise in inflation'
  ELSE
     WRITE(4,'(a60)') 'WITHOUT noise in inflation'
  END IF
  if (doSecondResamplingStep) THEN
     WRITE(4,'(a60)') 'APF uses second resampling step'
  END IF
  CLOSE(UNIT=4)
  CALL HRULEFILL

  filename = 'LOGMDD' // filext
  call savemat(logMDD, filename)
  WRITE (*,*) 'STORED MDD'
  WRITE (*,*) 'Mean MDD is:', sum(logMDD) / Ngrid
  DEALLOCATE (logMDD)

  filename = 'ESS' // filext
  call savemat(ESS, filename)
  WRITE (*,*) 'STORED ESS'
  DEALLOCATE (ESS)

  DEALLOCATE (y, yNaN)


  call hrulefill
  WRITE(*,*) 'DONE. BYE, BYE. (' // trim(adjustl(filext)) // ')'
  call hrulefill

  STOP

CONTAINS

  ! -----------------------------------------------------------------
  SUBROUTINE getarguments(Nparticles,Ngrid,doInflationNoise,datalabel, doSecondResamplingStep)

    INTENT(INOUT) Nparticles,Ngrid,doInflationNoise,datalabel, doSecondResamplingStep

    INTEGER :: counter, dummy
    INTEGER :: Nparticles,Ngrid
    LOGICAL :: doInflationNoise
    LOGICAL :: doSecondResamplingStep
    CHARACTER (LEN=100) :: datalabel
    CHARACTER(len=32) :: arg

    counter = 0

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') Nparticles
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') Ngrid
    END IF

    ! doInflationNoise
    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          doInflationNoise = .true.
       else
          doInflationNoise = .false.
       end if
    END IF

    ! datalabel
    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, datalabel) 
    END IF

    ! doSecondResamplingStep
    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          doSecondResamplingStep = .true.
       else
          doSecondResamplingStep = .false.
       end if
    END IF

  END SUBROUTINE getarguments
  ! -----------------------------------------------------------------


  ! -----------------------------------------------------------------
  SUBROUTINE readdata(y,filename,Ny,T)
    IMPLICIT NONE

    INTENT(IN) :: filename,Ny,T
    INTENT(INOUT) :: y
    CHARACTER (LEN=200) :: filename
    CHARACTER (LEN=500) :: fmtstr

    DOUBLE PRECISION, DIMENSION(:,:) :: y
    INTEGER i, T, Ny

    fmtstr = es30d16(Ny)
    !Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')
    DO i=1,T
       READ(4,fmtstr) y(:,i)
    END DO

    CLOSE(UNIT=4)

  END SUBROUTINE readdata

  ! -----------------------------------------------------------------

  ! -----------------------------------------------------------------
  SUBROUTINE readnandata(nanny,filename,Ny,T)
    IMPLICIT NONE

    INTENT(IN) :: filename,T,Ny
    INTENT(INOUT) :: nanny
    CHARACTER (LEN=100) :: filename
    CHARACTER (LEN=500) :: fmtstr

    LOGICAL, DIMENSION(:,:) :: nanny
    INTEGER :: work(Ny)

    INTEGER i, j, T, Ny

    fmtstr = '(I2' // repeat(',I2', Ny-1) // ')'

    !Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')

    DO i=1,T
       READ(4,fmtstr) (work(j), j=1,Ny)
       WHERE (work == 1) 
          nanny(:,i) = .TRUE.
       ELSEWHERE
          nanny(:,i) = .FALSE.
       END WHERE
    END DO

    CLOSE(UNIT=4)

  END SUBROUTINE readnandata
  ! -----------------------------------------------------------------


END PROGRAM main
! -----------------------------------------------------------------



! @\newpage\subsection{particlefilter}@
SUBROUTINE particleLLF(doSecondResamplingStep, doInflationNoise, T, logMDD, ESS, Ny, y, yNaN, Nparticles, Nx, NsigmaX, Nw, Ex0, sqrtVx00, p, a0, a0V,  sigaT, sigaDof,  lambda0, lambda0V, siglambdaT, siglambdaDof, Nsv, Eh0, Vh0, hvarT, hvarDof, sigmaT, sigmaDof, VSLstream)

  USE embox, only : savemat, savevec, int2str, mean, hrulefill

  use gibbsbox, only : drawNDXsysresample, igammaDraws
  use statespacebox, only : DLYAPsqrt
  use blaspack, only : pi, vechU,ivechU, vech, ivech, eye, symmetric, qrot, qrquery

  use vslbox
  use omp_lib
  ! use timerbox

  IMPLICIT NONE

  INTERFACE

     FUNCTION drawtruncnorm(N, x0, sig, lb, ub, VSLstream) RESULT(X)
       use vslbox
       INTEGER, INTENT(IN) :: N
       DOUBLE PRECISION, DIMENSION(N) :: x
       DOUBLE PRECISION, INTENT(IN)   :: sig, lb, ub
       DOUBLE PRECISION, DIMENSION(N), INTENT(IN) :: x0
       TYPE (VSL_STREAM_STATE),  INTENT(INOUT) :: VSLstream
     END FUNCTION drawtruncnorm

     FUNCTION drawdeltatruncnorm(N, x0, sig, lb, ub, VSLstream) RESULT(delta)
       use vslbox
       INTEGER, INTENT(IN) :: N
       DOUBLE PRECISION, DIMENSION(N) :: delta
       DOUBLE PRECISION, INTENT(IN)   :: lb, ub
       DOUBLE PRECISION, DIMENSION(N), INTENT(IN) :: x0, sig
       TYPE (VSL_STREAM_STATE),  INTENT(INOUT) :: VSLstream
     END FUNCTION drawdeltatruncnorm


  END INTERFACE


  INTENT(INOUT) :: VSLstream ! , timer
  INTENT(IN)    :: T,Ny,y,yNaN, Nx, NsigmaX, Nw, Ex0, sqrtVx00, Nsv,Eh0,Vh0, Nparticles, p, lambda0, lambda0V, a0, a0V, sigaT, sigaDof, siglambdaT, siglambdaDof, hvarT, hvarDof, sigmaT, sigmaDof
  INTENT(OUT) :: logMDD
  INTENT(OUT) :: ESS

  INTEGER :: J, I, K, T, Nparticles, Nx, Ny, Nsv, NsigmaX, p, Nw, Nsurveys

  ! OPEN MP
  INTEGER :: TID


  ! type(progresstimer) :: timer

  logical, intent(in) :: doInflationNoise

  double precision, parameter :: minParticleWeight = 1.0d-12

  DOUBLE PRECISION, DIMENSION(Ny,T) :: y
  LOGICAL, DIMENSION(Ny,T) :: yNaN
  DOUBLE PRECISION, DIMENSION(Nparticles,0:T) :: PARTICLEweights
  DOUBLE PRECISION, DIMENSION(Nparticles,T)   :: DRAWmdd

  ! APF llf correction
  DOUBLE PRECISION, DIMENSION(Nparticles)   :: APFkernelweights, APFlike
  DOUBLE PRECISION  :: APFkernelsum, loglikeAPFmax

  DOUBLE PRECISION, DIMENSION(T)   :: logMDD
  DOUBLE PRECISION, DIMENSION(T)   :: ESS

  ! DOUBLE PRECISION, DIMENSION(Nparticles,0:T) :: DRAWlambda
  ! DOUBLE PRECISION, DIMENSION(Nparticles,0:T) :: DRAWa
  ! DOUBLE PRECISION, DIMENSION(Nx,Nparticles,0:T)  :: DRAWxsig
  ! DOUBLE PRECISION, DIMENSION(Nx,Nparticles,0:T)  :: DRAWxhat
  ! DOUBLE PRECISION, DIMENSION(NsigmaX,Nparticles, 0:T)  :: DRAWsqrtSigmaX
  ! DOUBLE PRECISION, DIMENSION(Nx,Ny,Nparticles,T) :: DRAWxgain
  ! DOUBLE PRECISION, DIMENSION(Nparticles,Nsv,0:T) :: DRAWsvol

  ! ! scale parameters
  DOUBLE PRECISION, DIMENSION(Nparticles)     :: DRAWsiga
  DOUBLE PRECISION, DIMENSION(Nparticles)     :: DRAWsiglambda
  ! DOUBLE PRECISION, DIMENSION(Nparticles,Nsv) :: DRAWhInno
  DOUBLE PRECISION, DIMENSION(Nsv,Nparticles)   :: hInno ! helper variable, note the transpose
  DOUBLE PRECISION, DIMENSION(Nparticles,Ny)  :: DRAWsigma

  ! particles
  DOUBLE PRECISION :: xposterior(Nx,Nparticles), h(Nsv, Nparticles), SVol(Nsv,Nparticles), llf(Nparticles)
  DOUBLE PRECISION :: kernelweights(Nparticles) ! for unnormalized weights
  DOUBLE PRECISION  :: kernelsum, loglikemax
  INTEGER :: ndx(Nparticles)
  DOUBLE PRECISION :: shufflevec(Nparticles)

  ! state space objects
  DOUBLE PRECISION :: xprior(Nx), logdetSigmaY

  DOUBLE PRECISION :: lambda(Nparticles), lambdaPREV(Nparticles), lambda0, lambda0V
  DOUBLE PRECISION :: adrift(Nparticles), aPREV(Nparticles),  a0, a0V

  ! scale parameters
  DOUBLE PRECISION :: sigaT, siglambdaT, hvarT(Nsv), sigmaT(Ny)
  INTEGER :: sigaDof, siglambdaDof, hvarDof(Nsv), sigmaDof(Ny)

  DOUBLE PRECISION :: PREVsiglambdaT(Nparticles), PREVhvarT(Nparticles,Nsv), PREVsigmaT(Nparticles,Ny)
  INTEGER :: PREVsiglambdaDof, PREVhvarDof(Nsv), PREVsigmaDof(Ny)
  DOUBLE PRECISION :: lambdaDELTA(Nparticles), hDELTA(Nsv,Nparticles), resid(Ny,Nparticles)
  double precision :: xdraw(Nx,Nparticles) ! used for constructing resid

  ! AR1:
  DOUBLE PRECISION :: PREVsigaT(Nparticles)
  INTEGER :: PREVsigaDof
  DOUBLE PRECISION :: aDELTA(Nparticles)


  ! SQRT objects
  DOUBLE PRECISION :: sqrtSigmaX(Nx,Nx), sqrtSigmaY(Ny,Ny), Kgain(Nx,Ny,Nparticles), qrR(Ny+Nx+Nw,Ny+Nx)
  DOUBLE PRECISION, DIMENSION(NsigmaX, Nparticles) :: vecSqrtSigmaX
  INTEGER :: qrLwork

  DOUBLE PRECISION :: Ex0(Nx), sqrtVx0(Nx,Nx), sqrtVx00(Nx,Nx), A(Nx,Nx), B(Nx,Nw), Bsv(Nx,Nw), C(Ny,Nx,T), sqrtR(Ny,Ny), ytilde(Ny)
  ! DOUBLE PRECISION :: infgapcompanion(p,p), infgapcompanionh(p,p)
  DOUBLE PRECISION :: ygap0sqrtvariance(2*p,2*p), gapshock0loadings(2*p,Nw), gaptransition(2*p,2*p)

  DOUBLE PRECISION, DIMENSION(Nsv) :: Eh0, Vh0
  DOUBLE PRECISION :: minSVh(Nsv)


  INTEGER :: Nynonan

  ! CHARACTER (LEN=200) :: filename

  ! VSL
  INTEGER :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0
  type (vsl_stream_state) :: VSLstream
  double precision :: uniformdraws(2,T) ! two draws: one for each APF step

  ! index variables for state space
  INTEGER :: ndxTrendRE, ndxGapRE, ndxTrendSI, ndxGapSI, ndxGapREstart, ndxGapREstop, ndxGapSIstart, ndxGapSIstop, shockndxTrend, shockndxGap
  INTEGER :: ndxgap(2*p)

  logical, intent(in) :: doSecondResamplingStep

  ! CHARACTER (LEN=100) :: filename

  Nsurveys = Ny - 1
  minSVh   = log(0.001d0 ** 2)

  ! state-vector indices
  ndxTrendRE  = 1
  ndxGapRE    = 2
  ndxTrendSI  = 2+p
  ndxGapSI    = ndxTrendSI + 1

  ndxGapREstart = ndxGapRE
  ndxGapREstop  = ndxGapREstart + p - 1
  ndxGapSIstart = ndxGapSI
  ndxGapSIstop  = ndxGapSIstart + p - 1

  ndxgap = (/ ndxgapREstart : ndxGapREstop, ndxgapSIstart : ndxGapSIstop /)

  shockndxTrend = 1
  shockndxGap   = 2

  ! init sufficient statistics of scale parameters
  PREVsigaT   = sigaT
  PREVsigaDof = sigaDof

  PREVsiglambdaT   = siglambdaT
  PREVsiglambdaDof = siglambdaDof

  forall(k=1:Nparticles,j=1:Nsv) PREVhvarT(k,j) = hvarT(j)
  forall(j=1:Nsv)                PREVhvarDof(j) = hvarDof(j)

  forall(k=1:Nparticles,j=1:Ny) PREVsigmaT(k,j) = sigmaT(j)
  forall(j=1:Ny)                PREVsigmaDof(j) = sigmaDof(j)


  ! prepare state space
  ! A
  A = 0.0d0
  ! unit root in trend
  A(ndxTrendRE,ndxTrendRE) = 1.0d0
  ! kompanion for gap
  IF (p > 1) THEN
     FORALL(j=1:(p-1)) A(ndxGapRE+j,ndxGapRE-1+j) = 1.0d0
  END IF

  ! B
  B                           = 0.0d0
  B(ndxTrendRE,shockndxTrend) = 1.0d0
  B(ndxGapRE,shockndxGap)     = 1.0d0

  ! C
  C         = 0.0d0
  ! inflation
  C(1,ndxTrendRE,:)    = 1.0d0
  C(1,ndxGapRE,:)      = 1.0d0
  ! surveys
  C(2:Ny,ndxTrendSI,:) = 1.0d0


  ! Time 0 particles

  ! SV0
  errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nsv * Nparticles, h, 0.0d0, 1.0d0)
  FORALL (j=1:Nsv,k=1:Nparticles) h(j,k) = Eh0(j) + sqrt(Vh0(j)) * h(j,k)  
  SVol = exp(h * 0.5d0)

  ! Lambda(0)
  errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nparticles, lambdaPREV, lambda0, sqrt(lambda0V))
  lambda = lambdaPREV
  do while (ANY(lambda < 0.0d0) .OR. ANY(lambda > 1.0d0))
     errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nparticles, lambdaPREV, lambda0, sqrt(lambda0V)) ! a bit brute force to *always* redraw N random variables ..
     where (lambda < 0.0d0)   lambda = lambdaPREV
     where (lambda > 1.0d0)   lambda = lambdaPREV
  end do

  ! a(0)
  errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nparticles, aPREV, a0, sqrt(a0V))
  adrift  = aPREV
  do while (ANY(adrift < -1.0d0) .OR. ANY(adrift > 1.0d0))
     errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nparticles, aPREV, a0, sqrt(a0V)) ! a bit brute force to *always* redraw N random variables ..
     where (adrift < -1.0d0)  adrift = aPREV
     where (adrift > 1.0d0)   adrift = aPREV
  end do

  ! RB priors for linear states
  FORALL(k=1:Nparticles) xposterior(:,k) = Ex0

  ! prepare prior variance of linear states
  vecSqrtSigmaX       = 0.0d0
  !$OMP PARALLEL DO SHARED(vecSqrtSigmaX, p, SVol, lambda, adrift, Ny, Nx, Nw, Nsv, Nparticles, sqrtVx00, ndxgap, shockndxGap) PRIVATE(gaptransition,gapshock0loadings, sqrtVx0, ygap0sqrtvariance, errcode) DEFAULT(NONE)
  DO k=1,Nparticles

     sqrtVx0         = transpose(sqrtVx00)

     if (abs(adrift(k)) > 1.0d-4 .AND. lambda(k) > 1.0d-4) then 
        gaptransition                  = 0.0d0
        gaptransition(1:p,1:p)         = adrift(k)
        gaptransition(p+1:2*p,1:p)     = (1 - lambda(k)) * adrift(k)
        gaptransition(p+1:2*p,p+1:2*p) = lambda(k) * adrift(k)

        ! Fill in unconditional variance of stationary states
        ! allow for trendshockslopes, thought they are all zero here
        gapshock0loadings                              = 0.0d0
        gapshock0loadings(1,shockndxGap)               = SVol(shockndxGap,k)
        gapshock0loadings(p+1,shockndxGap)             = (1 - lambda(k)) * SVol(shockndxGap,k)

        CALL DLYAPsqrt(ygap0sqrtvariance, gaptransition, gapshock0loadings, 2 * p, Nw, errcode) 
        if (errcode /= 0) then
           write (*,*) 'DLYAP error (ygap0sqrtvariance -- init particlefilter)', errcode
           call savemat(gaptransition, 'gaptransition.debug')
           call savemat(gapshock0loadings, 'gapshock0loadings.debug')
           call savemat(ygap0sqrtvariance, 'ygap0sqrtvariance.debug')
           stop 1
        end if
        sqrtVx0(ndxgap,ndxgap) = ygap0sqrtvariance
     end if
     vecSqrtSigmaX(:,k)     = vechU(sqrtVx0,Nx)

  END DO
  !$OMP END PARALLEL DO 


  ! FORALL(i=1:Nsigmax,k=1:Nparticles) DRAWsqrtSigmaX(i,k,0)  = vecSqrtSigmaX(i,k)
  ! FORALL(i=1:Nx,k=1:Nparticles)  DRAWxhat(i,k,0)            = xposterior(i,k) 

  ! FORALL (i=1:Nsv,k=1:Nparticles) DRAWsvol(k,i,0) = SVol(i,k) ! transpose
  ! DRAWlambda(:,0) = lambda
  ! DRAWa(:,0)      = adrift
  PARTICLEweights = 1.0d0 / dble(Nparticles)
  DRAWmdd         = 0.0d0

  ! uniform draws for systematic resampling
  errcode = vdrnguniform(VSLmethodUniform, VSLstream, 2*T, uniformdraws, 0.0d0, 1.0d0)


  ! workspace query for qr decomposition
  qrR     = 0.0d0
  qrlwork = qrquery(qrR)

  ! CALL initprogressbar(timer, 15.0d0)
  DO j=1,T

     Nynonan = count(.not. yNaN(:,j))
     ! ------------------------------------------------------------------------------------------------------------------------------
     ! BEGIN: APF RESAMPLE STEP
     ! ------------------------------------------------------------------------------------------------------------------------------

     Nynonan = count(.not. yNaN(:,j))
     ! Sigma
     i=1
     if (doInflationNoise) then
        call igammaDraws(DRAWsigma(:,i), Nparticles, PREVsigmaT(:,i), PREVsigmaDof(i), VSLstream)
     else
        DRAWsigma(:,i) = 0.0d0
        PREVsigmaT(:,i)  = 0.0d0
     end if
     DO i=2,Ny 
        call igammaDraws(DRAWsigma(:,i), Nparticles, PREVsigmaT(:,i), PREVsigmaDof(i), VSLstream) 
     END DO

     !$OMP PARALLEL DO SHARED(xposterior, vecSqrtSigmaX, lambda, adrift, SVol, DRAWsigma, llf, Nparticles, Nsv, j, y, yNaN, Ny, Nx, Nw, Nynonan, Nsurveys, p, ndxTrendRE, ndxGapRE, ndxTrendSI, ndxGapSI, ndxGapREstart, ndxGapREstop, ndxGapSIstart, ndxGapSIstop, shockndxTrend, shockndxGap) FIRSTPRIVATE(A,B,C,qrLWORK) PRIVATE(ytilde, sqrtR, Bsv, logdetSigmaY, errcode, xprior, sqrtSigmaX, sqrtSigmaY,  qrR, TID) DEFAULT(NONE) SCHEDULE(STATIC)


     DO k = 1,Nparticles

        TID = 0
        !$ TID = OMP_GET_THREAD_NUM()


        ! 2) Fill Particles into state space

        ! update A 

        A(ndxGapRE,ndxGapRE)           = adrift(k)
        A(ndxtrendSI,ndxtrendRE)       = 1 - lambda(k)
        A(ndxtrendSI,ndxtrendSI)       = lambda(k)
        A(ndxgapSIstart:ndxgapSIstop,ndxgapREstart:ndxgapREstop) = (1 - lambda(k)) * adrift(k)
        A(ndxgapSIstart:ndxgapSIstop,ndxgapSIstart:ndxgapSIstop) = lambda(k) * adrift(k)

        ! update sqrtR
        sqrtR = 0.0d0
        forall (i=1:Ny) sqrtR(i,i) = sqrt(DRAWsigma(k,i)) 


        ! update C
        FORALL (i=1:Nsurveys) C(1+i,ndxGapSI,j) = adrift(k) ** i
        ! zero out missing obs
        DO i = 1, Ny
           if (yNaN(i,j)) then 
              C(i,:,j)     = 0.0d0 
              sqrtR(i,:)   = 0.0d0
           end if
        END DO


        ! update B
        B(ndxtrendSI,shockndxTrend)    = 1 - lambda(k)
        B(ndxgapSI,shockndxGap)        = 1 - lambda(k)

        ! Bsv
        FORALL (i=1:Nsv) Bsv(:,i)  = B(:,i) * SVol(i,k) 

        ! 3) Kalman Filter

        ! xprior = A * xposterior(-1)
     	xprior      = 0.0d0
        call DGEMV('n',Nx,Nx,1.0d0,A,Nx,xposterior(:,k),1,0.0d0,xprior,1)

        sqrtSigmaX = ivechU(vecSqrtSigmaX(:,k),Nx)

        ! fill directly into qrR
        qrR = 0.0d0
        qrR(1:Ny,1:Ny) = transpose(sqrtR)
        qrR(Ny+Nx+1:Ny+Nx+Nw,Ny+1:Ny+Nx) = transpose(Bsv)
        ! qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx) = sqrtSigmaX' * A' (sqrtSigmaX is already stored as transpose)
        call DGEMM('n','t',Nx,Nx,Nx,1.0d0,sqrtSigmaX,Nx,A,Nx,0.0d0,qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx),Nx)
        ! qrR(Ny+1:Ny+Nx+Nw,1:Ny) = qrR(Ny+1:Ny+Nx+Nw,Ny+1:Ny+Nx) * C'
        call DGEMM('n','t',Nx+Nw,Ny,Nx,1.0d0,qrR(Ny+1:Ny+Nx+Nw,Ny+1:Ny+Nx),Nx+Nw,C(:,:,j),Ny,0.0d0,qrR(Ny+1:Ny+Nx+Nw,1:Ny),Nx+Nw)

        ! QR decomposition
        call qrot(qrR, qrLWORK)

        ! map qr into Kalman objects
        sqrtSigmaY   = qrR(1:Ny,1:Ny) ! upper triangular
        sqrtSigmaX   = qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx) ! upper triangular
        ! Kgain(:,:,k) = transpose(qrR(1:Ny,Ny+1:Ny+Nx))

        ! ytilde = y - C * xprior
        ytilde = y(:,j)
        call DGEMV('n',Ny,Nx,-1.0d0,C(:,:,j),Ny,xprior,1,1.0d0,ytilde,1)

        ! ! compute resid
        ! do i=1,Ny
        !    if (.NOT. yNaN(i,j)) then
        !       resid(i,k) = ytilde(i) * sqrtR(i,i) / sqrtSigmaY(i,i)
        !    end if
        ! end do

        ! singularity fix: insert unit dummies for missing values
        do i=1,Ny
           if (yNaN(i,j)) sqrtSigmaY(i,i) = 1.0d0
           ! ytilde(i) = 0.0d0 -- not needed since y(i)=0 and C(i) * xprior also zero
        end do

        logdetSigmaY = 0.0d0
        DO i=1,Ny
           logdetSigmaY = logdetSigmaY + log(abs(sqrtSigmaY(i,i)))
        END DO
        logdetSigmaY = 2.0d0 * logdetSigmaY

        ! rotate ytilde (up to sign, consistent with rotation of K -- needed for llf computation)
        call dtrsv('U', 'T', 'N', Ny, sqrtSigmaY, Ny, ytilde, 1) ! recall: sqrtSigmaY is returned as upper triangular, right factor

        ! DO NOT STORE POSTERIORS FOR APF STEP
        ! ! xposterior = xprior + K * ytilde
        ! xposterior(:,k) = xprior
        ! call DGEMV('N',Nx,Ny,1.0d0,Kgain(:,:,k),Nx,ytilde,1,1.0d0,xposterior(:,k),1)


        ! rotate Kalman gain
        ! call dtrsm('R', 'U', 'T', 'N', Nx, Ny, 1.0d0, sqrtSigmaY, Ny, Kgain(:,:,k), Nx) ! recall: sqrtSigmaY is returned as upper triangular, right factor

        ! ! remove unit dummies
        ! do i=1,Ny
        !    if (yNaN(i,j)) sqrtSigmaY(i,i) = 0.0d0
        ! end do

        ! compute log-likelihood
        ! llf
        llf(k)       = -0.5d0 * (Nynonan * log(2.0d0 * pi) + logdetSigmaY + sum(ytilde ** 2))

        ! DO NOT STORE POSTERIORS FOR APF STEP
        ! vecSqrtSigmaX(:,k) = vechU(sqrtSigmaX,Nx)
        ! ! store state variances 
        ! call dsyrk('u', 't', Nx, Nx, 1.0d0, sqrtSigmaX, Nx, 0.0d0, SigmaX, Nx)
        ! forall (i=1:Nx) xsig(i,k) = sqrt(SigmaX(i,i))


     END DO ! k particles
     !$OMP END PARALLEL DO 


     if (Nynonan > 0) then

        ! Reweight particles for next round   
        loglikeAPFmax      = maxval(llf)
        llf                = llf - loglikeAPFmax

        APFlike = exp(llf)
        if (doSecondResamplingStep) then
           APFkernelweights     = APFlike / dble(Nparticles) 
           APFkernelsum         = sum(APFkernelweights)
           PARTICLEweights(:,j) = APFkernelweights / APFkernelsum

        else
           APFkernelweights     = APFlike * PARTICLEweights(:,j-1)
           APFkernelsum         = sum(APFkernelweights)
           PARTICLEweights(:,j) = APFkernelweights / APFkernelsum
        end if


        ! where (PARTICLEweights(:,j) < minParticleWeight) PARTICLEweights(:,j) = minParticleWeight
        ! PARTICLEweights(:,j) = PARTICLEweights(:,j) / sum(PARTICLEweights(:,j))

        call drawNDXsysresample(ndx, Nparticles, PARTICLEweights(:,j), Nparticles, uniformdraws(1,j))

        FORALL(k=1:Nparticles) shufflevec(k) = APFlike(ndx(k))
        APFlike = shufflevec

        DO i=1,Nx
           FORALL(k=1:Nparticles) shufflevec(k) = xposterior(i,ndx(k))
           xposterior(i,:) = shufflevec
        END DO

        DO i=1,Nsigmax
           FORALL(k=1:Nparticles) shufflevec(k) = vecSqrtSigmaX(i,ndx(k))
           vecSqrtSigmaX(i,:) = shufflevec
        END DO

        DO i=1,Nsv
           FORALL(k=1:Nparticles) shufflevec(k) = h(i,ndx(k))
           h(i,:) = shufflevec
        END DO

        FORALL(k=1:Nparticles) shufflevec(k) = lambda(ndx(k))
        lambda = shufflevec

        FORALL(k=1:Nparticles) shufflevec(k) = adrift(ndx(k))
        adrift = shufflevec

        ! reshuffle sufficient statistics for scale parameters
        FORALL(k=1:Nparticles) shufflevec(k) = PREVsigaT(ndx(k))
        PREVsigaT = shufflevec

        FORALL(k=1:Nparticles) shufflevec(k) = PREVsiglambdaT(ndx(k))
        PREVsiglambdaT = shufflevec

        DO i=1,Nsv
           FORALL(k=1:Nparticles) shufflevec(k) = PREVhvarT(ndx(k),i)
           PREVhvarT(:,i) = shufflevec
        END DO

        DO i=1,Ny
           FORALL(k=1:Nparticles) shufflevec(k) = PREVsigmaT(ndx(k),i)
           PREVsigmaT(:,i) = shufflevec
        END DO

        DO i=1,Ny
           FORALL(k=1:Nparticles) shufflevec(k) = DRAWsigma(ndx(k),i)
           DRAWsigma(:,i) = shufflevec
        END DO

     else ! i.e. Nynonan == 0
        ! do nothing since no information received
        ! PARTICLEweights(:,j) = 1 / dble(Nparticles)
     end if

     ! ------------------------------------------------------------------------------------------------------------------------------
     ! END: APF STEP
     ! ------------------------------------------------------------------------------------------------------------------------------

     ! 0) draw scale parameters
     ! siga
     call igammaDraws(DRAWsiga, Nparticles, PREVsigaT, PREVsigaDof, VSLstream)
     DRAWsiga = sqrt(DRAWsiga)
     ! siglambda
     call igammaDraws(DRAWsiglambda, Nparticles, PREVsiglambdaT, PREVsiglambdaDof, VSLstream)
     DRAWsiglambda = sqrt(DRAWsiglambda)
     ! hInno
     DO i=1,Nsv 
        call igammaDraws(hinno(i,:), Nparticles, PREVhvarT(:,i), PREVhvarDof(i), VSLstream) 
     END DO
     hinno = sqrt(hinno)
     ! forall (i=1:Nsv,k=1:Nparticles) hInno(i,k) = DRAWhInno(k,i) ! helper variable, provides better aligned access to the j data


     ! 1) Draw Particles 
     errcode     = vdrnggaussian(VSLmethodGaussian, VSLstream, Nsv * Nparticles, hDELTA, 0.0d0, 1.0d0)
     hDELTA      = hDELTA * hInno
     h           = h + hDELTA
     SVol        = exp(h * 0.5d0)


     lambdaPREV  = lambda
     lambdaDELTA = drawdeltatruncnorm(Nparticles, lambdaPREV, DRAWsiglambda, 0.0d0, 1.0d0, VSLstream)
     lambda      = lambdaPREV + lambdaDELTA

     aPREV      = adrift
     aDELTA     = drawdeltatruncnorm(Nparticles, aPREV, DRAWsiga, -1.0d0, 1.0d0, VSLstream)
     adrift     = aPREV + aDELTA

     ! ------------------------------------------------------------------------------------------------------------------------------
     ! BEGIN: MAIN PARTICLE STEP
     ! ------------------------------------------------------------------------------------------------------------------------------

     !$OMP PARALLEL DO SHARED(xposterior, vecSqrtSigmaX, lambda, adrift, SVol, Kgain, DRAWsigma, llf, Nparticles, Nsv, j, y, yNaN, Ny, Nx, Nw, Nynonan, Nsurveys, p, ndxTrendRE, ndxGapRE, ndxTrendSI, ndxGapSI, ndxGapREstart, ndxGapREstop, ndxGapSIstart, ndxGapSIstop, shockndxTrend, shockndxGap) FIRSTPRIVATE(A,B,C,qrLWORK) PRIVATE(ytilde, sqrtR, Bsv, logdetSigmaY, errcode, xprior, sqrtSigmaX, sqrtSigmaY, qrR, TID) DEFAULT(NONE) SCHEDULE(STATIC)


     DO k = 1,Nparticles

        TID = 0
        !$ TID = OMP_GET_THREAD_NUM()

        xprior      = 0.0d0
        ! SigmaX      = 0.0d0
        ! call ivech(SigmaX, vecSigmaX(:,k))

        ! 2) Fill Particles into state space

        ! update A 

        A(ndxGapRE,ndxGapRE)           = adrift(k)
        A(ndxtrendSI,ndxtrendRE)       = 1 - lambda(k)
        A(ndxtrendSI,ndxtrendSI)       = lambda(k)
        A(ndxgapSIstart:ndxgapSIstop,ndxgapREstart:ndxgapREstop) = (1 - lambda(k)) * adrift(k)
        A(ndxgapSIstart:ndxgapSIstop,ndxgapSIstart:ndxgapSIstop) = lambda(k) * adrift(k)

        ! update sqrtR
        sqrtR = 0.0d0
        forall (i=1:Ny) sqrtR(i,i) = sqrt(DRAWsigma(k,i)) 


        ! update C
        FORALL (i=1:Nsurveys) C(1+i,ndxGapSI,j) = adrift(k) ** i

        ! zero out missing obs
        DO i = 1, Ny
           if (yNaN(i,j)) then 
              C(i,:,j)     = 0.0d0 
              sqrtR(i,:)   = 0.0d0
           end if
        END DO


        ! update B
        B(ndxtrendSI,shockndxTrend)    = 1 - lambda(k)
        B(ndxgapSI,shockndxGap)        = 1 - lambda(k)

        ! Bsv
        FORALL (i=1:Nsv) Bsv(:,i)  = B(:,i) * SVol(i,k) 

        ! 3) Kalman Filter

        ! xprior = A * xposterior(-1)
        call DGEMV('n',Nx,Nx,1.0d0,A,Nx,xposterior(:,k),1,0.0d0,xprior,1)

        ! ------------------------------------------------------------------------
        ! SQRT KALMAN
        ! ------------------------------------------------------------------------
        sqrtSigmaX = ivechU(vecSqrtSigmaX(:,k),Nx)

        ! fill directly into qrR
        qrR = 0.0d0
        qrR(1:Ny,1:Ny) = transpose(sqrtR)
        qrR(Ny+Nx+1:Ny+Nx+Nw,Ny+1:Ny+Nx) = transpose(Bsv)
        ! qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx) = sqrtSigmaX' * A' (sqrtSigmaX is already stored as transpose)
        call DGEMM('n','t',Nx,Nx,Nx,1.0d0,sqrtSigmaX,Nx,A,Nx,0.0d0,qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx),Nx)
        ! qrR(Ny+1:Ny+Nx+Nw,1:Ny) = qrR(Ny+1:Ny+Nx+Nw,Ny+1:Ny+Nx) * C'
        call DGEMM('n','t',Nx+Nw,Ny,Nx,1.0d0,qrR(Ny+1:Ny+Nx+Nw,Ny+1:Ny+Nx),Nx+Nw,C(:,:,j),Ny,0.0d0,qrR(Ny+1:Ny+Nx+Nw,1:Ny),Nx+Nw)

        ! QR decomposition
        call qrot(qrR, qrLWORK)

        ! map qr into Kalman objects
        sqrtSigmaY   = qrR(1:Ny,1:Ny) ! upper triangular
        sqrtSigmaX   = qrR(Ny+1:Ny+Nx,Ny+1:Ny+Nx) ! upper triangular
        Kgain(:,:,k) = transpose(qrR(1:Ny,Ny+1:Ny+Nx))

        ! ytilde and logdetSigmaY
        ytilde = y(:,j)
        call DGEMV('n',Ny,Nx,-1.0d0,C(:,:,j),Ny,xprior,1,1.0d0,ytilde,1)

        ! singularity fix: insert unit dummies for missing values
        do i=1,Ny
           if (yNaN(i,j)) sqrtSigmaY(i,i) = 1.0d0
           ! ytilde(i) = 0.0d0 -- not needed since y(i)=0 and C(i) * xprior also zero
        end do

        logdetSigmaY = 0.0d0
        DO i=1,Ny
           logdetSigmaY = logdetSigmaY + log(abs(sqrtSigmaY(i,i)))
        END DO
        logdetSigmaY = 2.0d0 * logdetSigmaY
        ! rotate/normalize ytilde (up to sign, consistent with rotation of K)
        call dtrsv('U', 'T', 'N', Ny, sqrtSigmaY, Ny, ytilde, 1) ! recall: sqrtSigmaY is returned as upper triangular, right factor

        ! xposterior = xprior + K * ytilde
        xposterior(:,k) = xprior
        call DGEMV('N',Nx,Ny,1.0d0,Kgain(:,:,k),Nx,ytilde,1,1.0d0,xposterior(:,k),1)


        ! rotate Kalman gain into space of non-normalized ytilde
        call dtrsm('R', 'U', 'T', 'N', Nx, Ny, 1.0d0, sqrtSigmaY, Ny, Kgain(:,:,k), Nx) ! recall: sqrtSigmaY is returned as upper triangular, right factor

        ! remove unit dummies -- can be omitted since sqrtSigmaY not used any further
        ! do i=1,Ny
        !    if (yNaN(i,j)) sqrtSigmaY(i,i) = 0.0d0
        ! end do

        ! compute log-likelihood
        ! llf
        llf(k)       = -0.5d0 * (Nynonan * log(2.0d0 * pi) + logdetSigmaY + sum(ytilde ** 2))

        vecSqrtSigmaX(:,k) = vechU(sqrtSigmaX,Nx)
        ! store state variances 
        ! call dsyrk('u', 't', Nx, Nx, 1.0d0, sqrtSigmaX, Nx, 0.0d0, SigmaX, Nx)
        ! forall (i=1:Nx) xsig(i,k) = sqrt(SigmaX(i,i))


        ! ------------------------------------------------------------------------
        ! DONE: SQRT KALMAN
        ! ------------------------------------------------------------------------


     END DO ! k particles
     !$OMP END PARALLEL DO 

     ! ------------------------------------------------------------------------------------------------------------------------------
     ! END: MAIN PARTICLE STEP
     ! ------------------------------------------------------------------------------------------------------------------------------

     ! sample noise from Kalman-posteriors for updating SIGMA (further below)
     errcode  = vdrnggaussian(VSLmethodGaussian, VSLstream, Nx * Nparticles, xdraw, 0.0d0, 1.0d0)
     ! scale xdraw by vecSqrtSigmaX
     do k=1,Nparticles
        call DTPMV('u','t','n',Nx,vecSqrtSigmaX(:,k),xdraw(:,k),1)
     end do
     ! add mean to xdraw
     forall (k=1:Nparticles,i=1:Nx) xdraw(i,k) = xposterior(i,k) + xdraw(i,k)

     ! resid = y - C x
     forall (k=1:Nparticles,i=1:Ny) resid(i,k) = y(i,j)
     do k=1,Nparticles
        ! update C
        FORALL (i=1:Nsurveys) C(1+i,ndxGapSI,j) = adrift(k) ** i
        call dgemv('n',Ny,Nx,-1.0d0,C(:,:,j),Ny,xdraw(:,k),1,1.0d0,resid(:,k),1) ! could also do dgemm
        ! zero out when there were missing values
        where (yNaN(:,j)) resid(:,k) = 0.0d0
     end do

     ! done sampling noise


     ! MDD
     loglikemax        = maxval(llf)
     llf               = llf - loglikemax
     kernelweights     = exp(llf) / APFlike ! could overwrite llf and drop kernelweights, maybe call it llfkernel?
     kernelsum         = sum(kernelweights)
     logMDD(j)         = log(kernelsum / Nparticles) + log(APFkernelsum) + loglikemax ! note: loglikeAPFmax correction should be added to APFlike and subtracted from kernelweights (b/o APFlike in denominator), thus cancelling each other

     ! propagate sufficient statistics 
     if (Nynonan > 0) then ! nothing to propagate if there was no observed data
        FORALL(k=1:Nparticles)         PREVsigaT(k)         = PREVsigaT(k)      + aDELTA(k) ** 2
        FORALL(k=1:Nparticles)         PREVsiglambdaT(k)    = PREVsiglambdaT(k) + lambdaDELTA(k) ** 2
        FORALL(k=1:Nparticles,i=1:Nsv) PREVhvarT(k,i)       = PREVhvarT(k,i)    + hDELTA(i,k) ** 2

        if (doInflationNoise) then
           i = 1
           FORALL(k=1:Nparticles)  PREVsigmaT(k,i)  = PREVsigmaT(k,i)   + resid(i,k) ** 2
        end if
        FORALL(k=1:Nparticles,i=2:Ny)  PREVsigmaT(k,i)      = PREVsigmaT(k,i)   + resid(i,k) ** 2 ! note: missing obs handled by zero values of resid


        PREVsigaDof      = PREVsigaDof + 1
	PREVsiglambdaDof = PREVsiglambdaDof + 1
        PREVhvarDof      = PREVhvarDof + 1
        WHERE (.NOT. yNaN(:,j))
           PREVsigmaDof     = PREVsigmaDof + 1 
        END WHERE

        ! particles weights
        PARTICLEweights(:,j) = kernelweights / kernelsum
        ! where (PARTICLEweights(:,j) < minParticleWeight) PARTICLEweights(:,j) = minParticleWeight
        ! PARTICLEweights(:,j) = PARTICLEweights(:,j) / sum(PARTICLEweights(:,j))


        ! resample
        if (doSecondResamplingStep) then

           call drawNDXsysresample(ndx, Nparticles, PARTICLEweights(:,j), Nparticles, uniformdraws(2,j))


           DO i=1,Nx
              FORALL(k=1:Nparticles) shufflevec(k) = xposterior(i,ndx(k))
              xposterior(i,:) = shufflevec
           END DO

           DO i=1,Nsigmax
              FORALL(k=1:Nparticles) shufflevec(k) = vecSqrtSigmaX(i,ndx(k))
              vecSqrtSigmaX(i,:) = shufflevec
           END DO

           DO i=1,Nsv
              FORALL(k=1:Nparticles) shufflevec(k) = h(i,ndx(k))
              h(i,:) = shufflevec
           END DO
           ! SVol needs to be reshuffled, to prep the APF resample step
           DO i=1,Nsv 
              FORALL(k=1:Nparticles) shufflevec(k) = SVol(i,ndx(k))
              SVol(i,:) = shufflevec
           END DO

           FORALL(k=1:Nparticles) shufflevec(k) = lambda(ndx(k))
           lambda = shufflevec

           FORALL(k=1:Nparticles) shufflevec(k) = adrift(ndx(k))
           adrift = shufflevec

           ! reshuffle sufficient statistics for scale parameters
           FORALL(k=1:Nparticles) shufflevec(k) = PREVsigaT(ndx(k))
           PREVsigaT = shufflevec

           FORALL(k=1:Nparticles) shufflevec(k) = PREVsiglambdaT(ndx(k))
           PREVsiglambdaT = shufflevec

           DO i=1,Nsv
              FORALL(k=1:Nparticles) shufflevec(k) = PREVhvarT(ndx(k),i)
              PREVhvarT(:,i) = shufflevec
           END DO

           DO i=1,Ny
              FORALL(k=1:Nparticles) shufflevec(k) = PREVsigmaT(ndx(k),i)
              PREVsigmaT(:,i) = shufflevec
           END DO

        end if ! doSecondResamplingStep

     else ! i.e. Nynonan == 0
        !   PARTICLEweights(:,j) = 1 / dble(Nparticles)
     end if


     ! CALL progressbarcomment(dble(j) / dble(T), timer, 'Particle Step')

  END DO ! j=1,T

  ESS = 1 / sum(PARTICLEweights(:,1:T) ** 2, 1) / Nparticles 


END SUBROUTINE particleLLF


! @\newpage\subsection{drawtruncnorm}@
FUNCTION drawtruncnorm(N, x0, sig, lb, ub, VSLstream) RESULT(x)

  use vslbox
  IMPLICIT NONE

  INTENT(IN) :: N, x0, sig, lb, ub
  INTENT(INOUT) :: VSLstream
  INTEGER :: N
  DOUBLE PRECISION :: sig, lb, ub
  DOUBLE PRECISION, DIMENSION(N) :: x0, x, dx


  ! VSL
  TYPE (VSL_STREAM_STATE) :: VSLstream
  INTEGER :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0


  errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, sig)
  x = x0 + dx
  do while (ANY(x < lb) .OR. ANY(x > ub))
     errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, sig) ! a bit brute force to *always* redraw N random variables ..
     where (x < lb) 
        x = x0 + dx
     elsewhere (x > ub) 
        x = x0 + dx
     end where
  end do

END FUNCTION drawtruncnorm

! @\newpage\subsection{drawdeltatruncnorm}@
FUNCTION drawdeltatruncnorm(N, x0, sig, lb, ub, VSLstream) RESULT(delta)

  use vslbox
  IMPLICIT NONE

  INTENT(IN) :: N, x0, sig, lb, ub
  INTENT(INOUT) :: VSLstream
  INTEGER :: N
  DOUBLE PRECISION :: lb, ub
  DOUBLE PRECISION, DIMENSION(N) :: x0, x, dx, sig, delta


  ! VSL
  TYPE (VSL_STREAM_STATE) :: VSLstream
  INTEGER :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0


  errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, 1.0d0)
  dx = dx * sig
  x     = x0 + dx
  delta = dx
  do while (ANY(x < lb) .OR. ANY(x > ub))
     errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, 1.0d0) ! a bit brute force to *always* redraw N random variables ..
     dx = dx * sig
     where (x < lb) 
        x     = x0 + dx
        delta = dx
     elsewhere (x > ub) 
        x = x0 + dx
        delta = dx
     end where
  end do

END FUNCTION drawdeltatruncnorm

! @\newpage\subsection{drawtruncRW}@
FUNCTION drawtruncRW(N, T, x0, sig, lb, ub, VSLstream) RESULT(x)

  use vslbox
  IMPLICIT NONE

  INTENT(IN) :: N, T, x0, sig, lb, ub
  INTENT(INOUT) :: VSLstream
  INTEGER :: N,T
  DOUBLE PRECISION :: sig, lb, ub
  DOUBLE PRECISION :: x0, x(N,0:T), dx(N)

  integer :: ii

  ! VSL
  TYPE (VSL_STREAM_STATE) :: VSLstream
  INTEGER :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0


  x(:,0) = x0

  do ii=1,T

     errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, sig)
     x(:,ii) = x(:,ii-1) + dx

     do while (ANY(x(:,ii) < lb) .OR. ANY(x(:,ii) > ub))
        errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, N, dx, 0.0d0, sig) ! a bit brute force to *always* redraw N random variables ..
        where (x(:,ii) < lb) x(:,ii) = x(:,ii-1) + dx
        where (x(:,ii) > ub) x(:,ii) = x(:,ii-1) + dx
     end do

  end do


END FUNCTION drawtruncRW

! @\newpage\subsection{simXhatSI}@
FUNCTION simXhatSI(Nx, T, Ndraws, x0SI, xRE, lambda, p, infgapcompanion) RESULT(xSI)

  use vslbox
  IMPLICIT NONE

  INTENT(IN) :: Nx, T, Ndraws, x0SI, xRE, lambda, p, infgapcompanion

  INTEGER :: Nx,T,Ndraws,p
  DOUBLE PRECISION :: x0SI(Nx), xRE(Nx,0:T), lambda(Ndraws,0:T), xSI(Nx,Ndraws,0:T), infgapcompanion(p,p)
  DOUBLE PRECISION, DIMENSION(Nx,Nx) :: A
  INTEGER :: ndxTrend = 1, ndxGapStart = 2, ndxGapStop
  INTEGER :: ii, hh

  ndxGapStop = ndxGapStart + p - 1


  A = 0.0d0
  A(ndxTrend,ndxTrend) = 1.0d0
  A(ndxGapStart:ndxGapStop,ndxGapStart:ndxGapStop) = infgapcompanion

  forall (ii=1:Ndraws) xSI(:,ii,0) = x0SI
  forall (ii=1:Ndraws,hh=1:T) xSI(:,ii,hh) = xRE(:,hh)
  do hh=1,T
     do ii=1,Ndraws
        call dgemv('n',Nx,Nx,lambda(ii,hh),A,Nx,xSI(:,ii,hh-1),1,(1.0d0 - lambda(ii,hh)),xSI(:,ii,hh),1)
     end do
  end do

  ! ! xhatSI trend component 
  ! forall (ii=1:Ndraws) xSI(ndxTrend,ii,0) = x0SI(ndxTrend)
  ! do hh=1,T
  !    forall (ii=1:Ndraws) xSI(ndxTrend,ii,hh) = lambda(ii,hh) * xSI(ndxTrend,ii,hh-1) + (1.0d0 - lambda(ii,hh)) * xRE(ndxTrend,hh)
  ! end do

  ! ! simulate xhatSI gap component
  ! forall (ii=1:Ndraws) xSI(ndxGapStart:ndxGapStop,ii,0)  = x0SI(ndxGapStart:ndxGapStop)
  ! if ((p == 1) .AND. (infgapcompanion(1,1) == 0)) then
  !    xSI(ndxGapStart:ndxGapStop,:,1:T)  = 0.0d0
  ! else
  !    do hh=1,T
  !       do ii=1,Ndraws
  !          call dgemv('n',p,p,lambda(ii,hh),infgapcompanion,p,xSI(ndxGapStart:ndxGapStop,ii,hh-1),1,(1.0d0 - lambda(ii,hh)),xSI(ndxGapStart:ndxGapStop,ii,hh),1)
  !       end do
  !    end do
  ! end if



END FUNCTION simXhatSI

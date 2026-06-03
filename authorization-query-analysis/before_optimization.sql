CREATE   PROCEDURE [dbo].[GetAuthCaseListByUser] ( 
		@StartDate DATE,
		@EndDate DATE,
		@UserId	NVARCHAR(50),  
		@FilterValues	NVARCHAR(MAX) = NULL
)  
AS  
BEGIN  
	SET NOCOUNT ON;  
	DECLARE @AuthCaseList TABLE   
	(  
		MedicalCaseId INT
	);  
  
	DECLARE @AuthorizedPhysiciansAndLocations TABLE   
	(	
		PrimaryPhysicianId  NVARCHAR(50),  
		OrganizationId INT,  
		IsPhysician bit,  
		AccessTypeId int
	)  
   
	-- save the physicians and organizations to which the currect user has access
	insert into @AuthorizedPhysiciansAndLocations    
	(PrimaryPhysicianId, OrganizationId, IsPhysician, AccessTypeId)  
	select rad.PhysicianId, rad.OrganizationId, 0, r.AccessTypeId   
	from UserRoleMapping ra   
	INNER JOIN roles r on ra. RoleId = r.RoleId   
	INNER JOIN UserRoleAuthorizations rad on ra.UserRoleId = rad.UserRoleId  
	WHERE ra.UserId = @UserId and ra.IsActive = 1  
	and ( (AccessTypeId not in (1, 2, 3) and rad.IsActive = 1) or (AccessTypeId in (1, 2, 3)) ) ;  
  
	 -- records with AccessTypeId = 1 or 2 or 3, update primaryPhysicianid = userid, set IsPhysician = 1  
	 update @AuthorizedPhysiciansAndLocations set  
	  PrimaryPhysicianId = @UserId,   
	  IsPhysician = 1  
	 WHERE AccessTypeId in (1, 2, 3);  

	 --Step 1 execution - get list of medical cases by current user's authorization  
	 INSERT INTO @AuthCaseList  
	 SELECT cpd.MedicalCaseId  
	 FROM CasePlanningDetails cpd  
	 INNER JOIN @AuthorizedPhysiciansAndLocations auth  
	  ON (auth.PrimaryPhysicianId IS NULL OR cpd.PrimaryPhysicianId = auth.PrimaryPhysicianId )  
	  AND (auth.OrganizationId IS NULL OR cpd.OrganizationId = auth.OrganizationId )  
	  AND auth.AccessTypeId != 7
	 WHERE    
		(@StartDate IS NULL OR CAST(cpd.EventDateTime AS DATE) >= @StartDate) AND   
		(@EndDate IS NULL OR CAST(cpd.EventDateTime AS DATE) <= @EndDate) 
	 GROUP BY cpd.MedicalCaseId  

	 --Step 2: Get list of cases WHERE current user's authorized Physicians are present as additional Physicians   
	 if not exists (select * from @AuthorizedPhysiciansAndLocations WHERE PrimaryPhysicianId = @UserId)  
	 begin   
	  insert into @AuthorizedPhysiciansAndLocations    
		(PrimaryPhysicianId, OrganizationId, IsPhysician, AccessTypeId)  
		values (@UserId, null, 0, 1) ;  
	 end   
  
	 -- Step 3: Get the case list based on the authorization applicable for Special approver role
	 IF EXISTS (SELECT TOP 1 AccessTypeId FROM @AuthorizedPhysiciansAndLocations WHERE AccessTypeId = 11)
	 BEGIN
		INSERT INTO @AuthCaseList  
		SELECT cpd.MedicalCaseId  
		FROM CasePlanningDetails cpd  
		INNER JOIN CaseValidationDetails cv ON cpd.MedicalCaseId = cv.MedicalCaseId AND cv.IsCompliant = 0 AND cv.IsActive = 1
		INNER JOIN @AuthorizedPhysiciansAndLocations auth ON (auth.PrimaryPhysicianId IS NULL OR cpd.PrimaryPhysicianId = auth.PrimaryPhysicianId )  
		AND (auth.OrganizationId IS NULL OR cpd.OrganizationId = auth.OrganizationId )  
		AND auth.AccessTypeId = 7
		WHERE     
			(@StartDate IS NULL OR CAST(cpd.EventDateTime AS DATE) >= @StartDate) AND   
			(@EndDate IS NULL OR CAST(cpd.EventDateTime AS DATE) <= @EndDate) 
		GROUP BY cpd.MedicalCaseId;  
	  END


 IF @FilterValues IS NULL  
 BEGIN   
  SELECT MedicalCaseId FROM @AuthCaseList GROUP BY MedicalCaseId;  
 END   
 ELSE  
 BEGIN   
	-- filterby json data in a temp table. 
	DROP TABLE IF EXISTS #FilterValues;
	CREATE TABLE #FilterValues ([Fields] NVARCHAR(150),[Values] NVARCHAR(250))

	DECLARE @PhysicianExist BIT = 0
			,@CaseStatusExist BIT = 0
			,@OrganizationExist BIT = 0;

	IF EXISTS (SELECT 1 FROM OPENJSON(@FilterValues)) and ISJSON (@FilterValues)=1
	BEGIN
		--insert filterby json data in a temp table. 
		INSERT INTO #FilterValues ([Fields],[Values])
		SELECT [Fields],[Values] from udf_ExtractFilterKeyValues(@FilterValues);
	
		-- check is filter values available
		SELECT 
			@PhysicianExist = max(case when Fields = 'Physicians' then 1 else 0 end),
			@OrganizationExist = max(case when Fields = 'Organizations' then 1 else 0 end),
			@CaseStatusExist = max(case when Fields = 'CaseStatus' then 1 else 0 end)
		FROM #FilterValues;
	END 

	--Apply the filter ad return final list of MedicalCaseIds
	SELECT cpd.MedicalCaseId 
	FROM CasePlanningDetails cpd 
	INNER JOIN MedicalCases CSC on cpd.MedicalCaseId = CSC.MedicalCaseId
	INNER JOIN @AuthCaseList tmpc on tmpc.MedicalCaseId = cpd.MedicalCaseId
	LEFT JOIN CaseAdditionalPhysicians cap ON cap.IsActive = 1 AND cpd.PlanningDetailId = cap.PlanningDetailId AND cap.CaseAdditionalPhysicianId IS NOT NULL
	WHERE 
			-- filter Providers values 
			(@PhysicianExist <> 1 OR (cpd.PrimaryPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = 'Physicians') 
							OR cap.AdditionalPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = 'Physicians'))) AND
			-- filter Organization values 
			(@OrganizationExist <> 1 OR cpd.OrganizationId in (SELECT [Values] FROM #FilterValues WHERE Fields = 'Organizations')) AND
			-- filter Case Status values 
			(@CaseStatusExist <> 1 OR CSC.CaseStatusId in (SELECT [Values] FROM #FilterValues WHERE Fields = 'CaseStatus')) 

	GROUP BY cpd.MedicalCaseId
	DROP TABLE IF EXISTS #FilterValues;
 END  
   
SET NOCOUNT OFF;  
END;  
GO



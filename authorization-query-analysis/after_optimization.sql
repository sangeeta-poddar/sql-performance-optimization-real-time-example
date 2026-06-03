CREATE    PROCEDURE [dbo].[USP_GetAuthCaseListByUser] ( 
		@StartDate DATE,
		@EndDate DATE,
		@UserId	NVARCHAR(50),  
		@FilterValues	NVARCHAR(MAX) = NULL
)  
AS  
BEGIN  
SET NOCOUNT ON;  

	DECLARE @sql nvarchar(max)
	DECLARE @sqlbasicfilter nvarchar(max) = ''
	DECLARE @sqlfilter nvarchar(max) = ''

	IF @FilterValues IS NOT NULL  
	BEGIN  
		--insert filterby json data into a temp table and prepare  the sql condition with filter values
		DROP TABLE IF EXISTS #FilterValues;
		CREATE TABLE #FilterValues ([Fields] NVARCHAR(150),[Values] NVARCHAR(250), [IntValues] INT)

		IF EXISTS (SELECT 1 FROM OPENJSON(@FilterValues)) and ISJSON (@FilterValues)=1
		BEGIN
			--insert filterby json data in a temp table. 
			INSERT INTO #FilterValues ([Fields],[Values])
			SELECT [Fields],[Values] from udf_ExtractFilterKeyValues(@FilterValues);
			
			UPDATE #FilterValues SET [IntValues] = [Values], [Values] = NULL
			WHERE Fields IN ('Organization', 'CaseStatus', 'MedicalCaseId')

			-- build filter condition, add joins if necessary.
			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'CaseStatus')
				SET @sqlfilter = @sqlfilter + ' INNER JOIN MedicalCases mc on t.MedicalCaseId = mc.MedicalCaseId'

			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'Physician')
				SET @sqlfilter = @sqlfilter + ' INNER JOIN CasePlanningDetails cpd ON t.MedicalCaseId = cpd.MedicalCaseId
				LEFT JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1 AND cap.AdditionalPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = ''Physician'')
				WHERE (cpd.PrimayPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = ''Physician'') OR cap.AdditionalPhysicianId IS NOT NULL)'
			ELSE  
				SET @sqlfilter = @sqlfilter + ' WHERE 1=1'

			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'CaseStatus')
				SET @sqlfilter = @sqlfilter + ' AND mc.CaseStatusId in (SELECT [IntValues] FROM #FilterValues WHERE Fields = ''CaseStatus'')'
	
			-- prepare the sql statement with filter values from the cases related tables. it should be applied at the initial stage of finding the authorized cases.
			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'Organization')
				SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.OrganizationId in (SELECT [IntValues] FROM #FilterValues WHERE Fields = ''Organization'')'
			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'MedicalCaseId')
				SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.MedicalCaseId in (SELECT [IntValues] FROM #FilterValues WHERE Fields = ''MedicalCaseId'')'
			IF EXISTS (SELECT 1 FROM #FilterValues WHERE Fields = 'PrimaryPhysician')
				SET @sqlbasicfilter = @sqlbasicfilter + ' AND cpd.PrimayPhysicianId in (SELECT [Values] FROM #FilterValues WHERE Fields = ''PrimaryPhysician'')'
		END 
	END
	--select * from #FilterValues

	CREATE TABLE #AuthorizedPhysiciansAndOrganizations  (
		PrimayPhysicianId  NVARCHAR(50),  
		OrganizationId INT, 
		UserFlag TINYINT
	)  
	
	-- Store the comma separated list of AccessTypeId for the logged in user
	DECLARE @authaccessTypes varchar (50)
	select @authaccessTypes = string_agg(AccessTypeId,',')
	from UserRoleMapping urm   
	inner join roles r on urm.RoleId = r.RoleId   
	where urm.UserId = @UserId and urm.IsActive = 1
	group by urm.UserId

	-- Insert RoleAuthorization records for Physician role (if current user has physician role)
	insert into #AuthorizedPhysiciansAndOrganizations    
	(PrimayPhysicianId, OrganizationId, UserFlag)  		
	select DISTINCT 
	@UserId, ura.OrganizationId, 1
	from UserRoleMapping urm   
	inner join Roles r on urm. RoleId = r.RoleId   
	inner join UserRoleAuthorizations ura on urm.UserRoleId = ura.UserRoleId  
	where urm.UserId = @UserId and urm.IsActive = 1  
	and AccessTypeId in (1, 2, 3) and ura.IsActive = 1 
	
	-- Insert distinct set of RoleAuthorization records for non-Physician role (if current user has non-physician role)
	insert into #AuthorizedPhysiciansAndOrganizations    
	(PrimayPhysicianId, OrganizationId)  		
	select DISTINCT 
	ura.PhysicianId, ura.OrganizationId
	from UserRoleMapping urm   
	inner join Roles r on urm. RoleId = r.RoleId   
	inner join UserRoleAuthorizations ura on urm.UserRoleId = ura.UserRoleId  
	where urm.UserId = @UserId and urm.IsActive = 1  
	and AccessTypeId not in (1, 2, 3, 7) and ura.IsActive = 1 
	
	-- Insert RoleAuthorization records for special approver role
	insert into #AuthorizedPhysiciansAndOrganizations    
	(PrimayPhysicianId, OrganizationId, UserFlag)  		
	select 
	ura.PhysicianId, ura.OrganizationId, 2
	from UserRoleMapping urm   
	inner join Roles r on urm. RoleId = r.RoleId   
	inner join UserRoleAuthorizations ura on urm.UserRoleId = ura.UserRoleId  
	where urm.UserId = @UserId and urm.IsActive = 1  
	and AccessTypeId in (7) and ura.IsActive = 1 ;  

	-- Increament @EndDate by 1 day to avoid the date conversion of eventdatetime in the where clause
	IF @EndDate IS NOT NULL 
		SET @EndDate = DATEADD(day, 1, @EndDate)

	SET @sql = 'SELECT t.MedicalCaseId FROM (SELECT MedicalCaseId FROM MedicalCases WHERE 1=2'

	--Step 1 - get list of cases for Physician role (include cases for secondary Physicians)
	IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE in (1, 2, 3))
	BEGIN
		SET @sql = @sql  + ' UNION
		SELECT cpd.MedicalCaseId  
		FROM CasePlanningDetails cpd  
		INNER JOIN #AuthorizedPhysiciansAndOrganizations auth ON cpd.OrganizationId = auth.OrganizationId 
		WHERE auth.UserFlag = 1 AND 
		(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
		(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
		AND cpd.PrimayPhysicianId = @UserId'+@sqlbasicfilter+ 
		' UNION
		SELECT cpd.MedicalCaseId  
		FROM CasePlanningDetails cpd  
		INNER JOIN #AuthorizedPhysiciansAndOrganizations auth ON cpd.OrganizationId = auth.OrganizationId 
		INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1
		WHERE auth.UserFlag = 1 AND 
		(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
		(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
		AND cap.AdditionalPhysicianId = @UserId'+@sqlbasicfilter
	END
	ELSE IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE not in (1, 2, 3, 7))
	BEGIN
		--get list of cases where logged in user is not Physician but present as secondary Physician
		SET @sql = @sql  + ' UNION
		SELECT cpd.MedicalCaseId  
		FROM CasePlanningDetails cpd  
		INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1
		WHERE 
		(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
		(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
		AND cap.AdditionalPhysicianId = @UserId'+@sqlbasicfilter
	END

	--Step 2 - get cases for non-Physician users
	IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE not in (1, 2, 3, 7))
	BEGIN
		--Step 2.1 - get cases by Organization
		IF EXISTS (SELECT 1 FROM #AuthorizedPhysiciansAndOrganizations WHERE UserFlag IS NULL AND PrimayPhysicianId IS NULL AND OrganizationId IS NOT NULL AND ProcedureUnitId IS NULL)
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.OrganizationId = nauth.OrganizationId  
			WHERE nauth.UserFlag IS NULL AND 
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NULL AND nauth.OrganizationId IS NOT NULL '+@sqlbasicfilter

		--Step 2.2 - get cases by PrimaryPhysician
		IF EXISTS (SELECT 1 FROM #AuthorizedPhysiciansAndOrganizations WHERE UserFlag IS NULL AND PrimayPhysicianId IS NOT NULL AND OrganizationId IS NULL)
		BEGIN
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.PrimayPhysicianId = nauth.PrimayPhysicianId 
			WHERE nauth.UserFlag IS NULL AND 
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NOT NULL AND nauth.OrganizationId IS NULL'+@sqlbasicfilter

			-- include check for secondary Physician
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1 
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cap.AdditionalPhysicianId = nauth.PrimayPhysicianId
			WHERE nauth.UserFlag IS NULL AND  
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NOT NULL AND nauth.OrganizationId IS NULL'+@sqlbasicfilter
		END
				
		--Step 2.3 - get cases by PrimaryPhysician, Organization
		IF EXISTS (SELECT 1 FROM #AuthorizedPhysiciansAndOrganizations WHERE UserFlag IS NULL AND PrimayPhysicianId IS NOT NULL AND OrganizationId IS NOT NULL)
		BEGIN
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.PrimayPhysicianId = nauth.PrimayPhysicianId 
			AND cpd.OrganizationId = nauth.OrganizationId  
			WHERE nauth.UserFlag IS NULL AND 
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NOT NULL AND nauth.OrganizationId IS NOT NULL '+@sqlbasicfilter
						
			-- include check for secondary Physician
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.OrganizationId = nauth.OrganizationId 
			INNER JOIN CaseAdditionalPhysicians cap ON cpd.PlanningDetailId = cap.PlanningDetailId AND cap.IsActive = 1 AND cap.AdditionalPhysicianId = nauth.PrimayPhysicianId
			WHERE nauth.UserFlag IS NULL AND  
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NOT NULL AND nauth.OrganizationId IS NOT NULL '+@sqlbasicfilter
		END	

	END

	--Step 3 - get list of cases for special approver role
	IF EXISTS (SELECT VALUE FROM string_split(@authaccessTypes,',') WHERE VALUE in (7))
	BEGIN
		--Step 3.1 - get cases by Organization
		IF EXISTS (SELECT 1 FROM #AuthorizedPhysiciansAndOrganizations WHERE UserFlag = 2 AND PrimayPhysicianId IS NULL AND OrganizationId IS NOT NULL)
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN Case_RuleResults CRR ON cpd.MedicalCaseId = CRR.MedicalCaseId AND CRR.RuleCompliantBl = 0 AND CRR.IsActive = 1
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.OrganizationId = nauth.OrganizationId  
			WHERE nauth.UserFlag = 2 AND 
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NULL AND nauth.OrganizationId  IS NOT NULL '+@sqlbasicfilter

		--rare scenario 
		--Step 3.2 - get cases by PrimaryPhysician / Organization
		IF EXISTS (SELECT 1 FROM #AuthorizedPhysiciansAndOrganizations WHERE UserFlag IS NULL AND PrimayPhysicianId IS NOT NULL)
			SET @sql = @sql  + ' UNION
			SELECT cpd.MedicalCaseId  
			FROM CasePlanningDetails cpd  
			INNER JOIN #AuthorizedPhysiciansAndOrganizations nauth ON cpd.PrimayPhysicianId = nauth.PrimayPhysicianId 
			AND (nauth.OrganizationId IS NULL OR cpd.OrganizationId = nauth.OrganizationId )
			WHERE nauth.UserFlag IS NULL AND  
			(@StartDate IS NULL OR cpd.EventDateTime >= @StartDate) AND   
			(@EndDate IS NULL OR cpd.EventDateTime < @EndDate) 
			AND nauth.PrimayPhysicianId IS NOT NULL '+@sqlbasicfilter

	END
	SET @sql = @sql+') t'

	SET @sql = @sql+@sqlfilter
	--print @sql
	EXEC sp_executesql @sql, N'@UserId NVARCHAR(50), @StartDate DATE, @EndDate DATE', @UserId=@UserId, @StartDate=@StartDate, @EndDate=@EndDate

SET NOCOUNT OFF;  
END;  
GO

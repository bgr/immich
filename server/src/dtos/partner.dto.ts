import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsNotEmpty, IsOptional } from 'class-validator';
import { UserResponseDto } from 'src/dtos/user.dto';
import { PartnerAccess } from 'src/enum';
import { PartnerDirection } from 'src/repositories/partner.repository';
import { ValidateEnum, ValidateUUID } from 'src/validation';

export class PartnerCreateDto {
  @ValidateUUID({ description: 'User ID to share with' })
  sharedWithId!: string;
}

export class PartnerUpdateDto {
  @ApiPropertyOptional({ description: 'Show partner assets in timeline' })
  @IsOptional()
  inTimeline?: boolean;

  @ValidateEnum({ enum: PartnerAccess, name: 'PartnerAccess', description: 'Partner access level', optional: true })
  accessLevel?: PartnerAccess;
}

export class PartnerSearchDto {
  @ValidateEnum({ enum: PartnerDirection, name: 'PartnerDirection', description: 'Partner direction' })
  direction!: PartnerDirection;
}

export class PartnerResponseDto extends UserResponseDto {
  @ApiPropertyOptional({ description: 'Show in timeline' })
  inTimeline?: boolean;

  @ApiProperty({ description: 'Partner access level', enum: PartnerAccess, enumName: 'PartnerAccess' })
  accessLevel!: PartnerAccess;
}
